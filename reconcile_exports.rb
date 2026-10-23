#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"

class ReconcileError < StandardError; end

STATE_DIR = File.expand_path(".state", __dir__)
DEFAULT_DATA_REPO = File.expand_path("../export-chats-data", __dir__)
INVENTORY_GLOB = "*Project Inventory.json"
QUEUE_SCHEMA = "adventurefinder-chat-pending-queue/v0.1"
RECONCILIATION_SCHEMA = "adventurefinder-chat-reconciliation/v0.1"

module ReconcileHelpers
  module_function

  def normalize_title(value)
    value.to_s
      .unicode_normalize(:nfkc)
      .downcase
      .tr("‐‑‒–—−·/\\_:*?\"<>|", "                 ")
      .gsub(/[^\p{L}\p{N}]+/u, " ")
      .strip
      .gsub(/\s+/, " ")
  end

  def parse_export_filename(path)
    name = File.basename(path, ".md")
    match = name.match(/\A(\d{4}-\d{2}-\d{2})\s+-\s+(.+)\z/)

    if match
      { date: match[1], title: match[2] }
    else
      { date: nil, title: name }
    end
  end

  # Encode parsed JSON for the browser's checksum: type tags, insertion order,
  # and big-endian IEEE-754 numbers. Returns text; accepts only JSON-shaped input.
  def checkpoint_encoding(value)
    case value
    when NilClass then "n"
    when TrueClass then "b1"
    when FalseClass then "b0"
    when String then "s#{JSON.generate(value)}"
    when Numeric then "d#{[value.zero? ? 0.0 : value.to_f].pack("G").unpack1("H*")}"
    when Array then "[#{value.map { |entry| checkpoint_encoding(entry) }.join(",")}]"
    when Hash then "{#{value.map { |key, entry| "#{JSON.generate(key)}:#{checkpoint_encoding(entry)}" }.join(",")}}"
    else raise ReconcileError, "non-JSON checkpoint value"
    end
  end

  # Normalize epoch seconds or strict zoned ISO input into UTC milliseconds and a
  # valid/missing/invalid status. Returns a Hash; invalid evidence never invents dates.
  # This is the timestamp contract in AUTOMATED_EXPORT.md, shared with the browser.
  def inventory_timestamp(value)
    return { value: nil, status: "missing" } if value.nil? || value == ""

    milliseconds =
      if value.is_a?(Integer) || value.is_a?(Float)
        return { value: nil, status: "invalid" } unless value.finite?
        scaled = value * 1000
        lower = scaled.floor
        lower + (scaled - lower >= 0.5 ? 1 : 0)
      elsif value.is_a?(String)
        match = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})\z/.match(value)
        return { value: nil, status: "invalid" } unless match
        year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
        zone = match[8]
        offset_hour = zone == "Z" ? 0 : zone[1, 2].to_i
        offset_minute = zone == "Z" ? 0 : zone[4, 2].to_i
        return { value: nil, status: "invalid" } unless year.between?(1, 9999) && Date.valid_date?(year, month, day, Date::GREGORIAN) &&
          hour <= 23 && minute <= 59 && second <= 59 && offset_hour <= 14 && offset_minute <= 59 &&
          (offset_hour != 14 || offset_minute.zero?) && zone != "-00:00"
        (Time.iso8601(value).to_r * 1000).to_i
      end
    return { value: nil, status: "invalid" } unless milliseconds &&
      milliseconds.between?(-62_135_596_800_000, 253_402_300_799_999)

    { value: Time.at(Rational(milliseconds, 1000)).utc.iso8601(3), status: "valid" }
  rescue ArgumentError, RangeError, FloatDomainError
    { value: nil, status: "invalid" }
  end

  # Return UTC/local creation-date candidates for supported inventory evidence;
  # missing/invalid input returns [], with no permissive parsing or current-date fallback.
  def time_date_candidates(value)
    normalized = inventory_timestamp(value)
    return [] unless normalized[:status] == "valid"

    time = Time.iso8601(normalized[:value])
    [time.utc.strftime("%Y-%m-%d"), time.getlocal.strftime("%Y-%m-%d")].uniq
  end

  def atomic_json(path, object)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp-#{Process.pid}"
    File.binwrite(temp, JSON.pretty_generate(object) + "\n")
    File.rename(temp, path)
  ensure
    File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end
end

require_relative "snapshot_archive"

# Match known inventory IDs to archival evidence and write resumable queues.
# Accepts explicit archive/inventory paths; raises ReconcileError on unsafe evidence.
class ExportReconciler
  include ReconcileHelpers

  attr_reader :data_repo, :inventory_path

  def initialize(data_repo:, inventory_path: nil)
    @data_repo = File.expand_path(data_repo)
    raise ReconcileError, "data repo does not exist: #{@data_repo}" unless Dir.exist?(@data_repo)

    @inventory_path = inventory_path ? File.expand_path(inventory_path) : newest_inventory
    raise ReconcileError, "inventory file not found" unless @inventory_path && File.file?(@inventory_path)
  end

  # Read and validate the selected inventory, reconcile known IDs, then write local
  # queues/runners and return a report. Raises ReconcileError/JSON/file errors.
  def run
    inventory = JSON.parse(File.binread(inventory_path))
    project_id = inventory.fetch("project_id")
    records = inventory_records(inventory)
    inventory_by_id = records.to_h { |record| [record.fetch("id"), record] }

    if inventory_by_id.length != records.length
      raise ReconcileError, "inventory contains duplicate conversation IDs"
    end

    observed_count = inventory["observed_conversation_count"]
    count = inventory["schema"] == "adventurefinder-chat-project-inventory/v0.2" ? inventory["known_conversation_count"] : observed_count
    if count && count != records.length
      raise ReconcileError,
        "inventory record count #{count} does not match #{records.length} unique records"
    end

    markdown_payloads = unique_markdown_payloads
    title_index = records.group_by { |record| ReconcileHelpers.normalize_title(record["title"]) }

    assignments = []
    unresolved = []

    markdown_payloads.each do |payload|
      match = match_payload(payload, title_index)
      if match
        assignments << payload.merge(match)
      else
        unresolved << payload
      end
    end

    # A conversation ID may legitimately have multiple historical exports. Collapse
    # them only after matching, and keep all evidence in the report.
    by_id = assignments.group_by { |entry| entry.fetch(:conversation_id) }
    completed = by_id.map do |id, entries|
      record = inventory_by_id.fetch(id)
      {
        "id" => id,
        "title" => record["title"],
        "create_time" => record["create_time"],
        "match_reasons" => entries.map { |entry| entry.fetch(:match_reason) }.uniq.sort,
        "markdown_files" => entries.flat_map { |entry| entry.fetch(:paths) }.uniq.sort,
        "markdown_sha256" => entries.map { |entry| entry.fetch(:sha256) }.uniq.sort
      }
    end.sort_by { |entry| [entry["title"].to_s.downcase, entry["id"]] }

    completed_ids = completed.map { |entry| entry.fetch("id") }.to_h { |id| [id, true] }

    # Raw JSON from prior automated captures is definitive identity evidence.
    raw_completed = raw_capture_ids(inventory_by_id)
    raw_completed.each do |id|
      next if completed_ids[id]

      record = inventory_by_id.fetch(id)
      completed << {
        "id" => id,
        "title" => record["title"],
        "create_time" => record["create_time"],
        "match_reasons" => ["raw-conversation-id"],
        "markdown_files" => markdown_files_for_id(id),
        "markdown_sha256" => []
      }
      completed_ids[id] = true
    end
    completed.sort_by! { |entry| [entry["title"].to_s.downcase, entry["id"]] }

    pending = records.reject { |record| completed_ids[record.fetch("id")] }
      .sort_by { |record| [record["create_time"].to_s, record.fetch("id")] }
    freshness_states = []
    legacy_evidence = completed
    if inventory["schema"] == "adventurefinder-chat-project-inventory/v0.2"
      archive = SnapshotArchive.new(root: data_repo, project_id: project_id, account_id: inventory["account_id"])
      pending, freshness_states = archive.select(records.sort_by { |record| record.fetch("id") }, completed_ids.keys)
      completed_ids = freshness_states.select { |entry| entry["state"] == "verified-unchanged" }.to_h { |entry| [entry["id"], true] }
      completed = freshness_states.select { |entry| entry["state"] == "verified-unchanged" }
    else
      completed_ids = {}
      completed = []
      pending = records.sort_by { |record| [record["create_time"].to_s, record.fetch("id")] }
      freshness_states = records.map do |record|
        { "id" => record["id"], "state" => "unknown-legacy-inventory", "selected" => false, "current" => nil }
      end
    end
    local_date = ENV["CHAT_EXPORT_ONLY_LOCAL_DATE"]
    if local_date
      begin
        raise Date::Error unless /\A\d{4}-\d{2}-\d{2}\z/.match?(local_date) &&
          Date.iso8601(local_date).iso8601 == local_date
      rescue Date::Error
        raise ReconcileError, "CHAT_EXPORT_ONLY_LOCAL_DATE must be YYYY-MM-DD"
      end
      unless inventory["schema"] == "adventurefinder-chat-project-inventory/v0.2" &&
          records.all? { |record| record["update_time_status"] == "valid" }
        raise ReconcileError, "date scope requires v0.2 inventory with all update timestamps valid"
      end
      active_ids = records.select do |record|
        Time.iso8601(record["update_time"]).getlocal.strftime("%F") == local_date
      end.to_h { |record| [record["id"], true] }
      pending_ids = pending.to_h { |record| [record["id"], true] }
      missing = active_ids.keys.reject { |id| pending_ids[id] || completed_ids[id] }
      unless missing.empty?
        raise ReconcileError, "date scope cannot account for active IDs: #{missing.join(', ')}"
      end
      pending.select! { |record| active_ids[record["id"]] }
      freshness_states.each { |state| state["selected"] = false unless active_ids[state["id"]] }
    end
    report = {
      "schema" => RECONCILIATION_SCHEMA,
      "generated_at" => Time.now.utc.iso8601,
      "data_repo" => data_repo,
      "inventory_file" => relative_to_data_repo(inventory_path),
      "inventory_sha256" => ReconcileHelpers.sha256_file(inventory_path),
      "project_id" => project_id,
      "inventory_count" => records.length,
      "inventory_coverage" => inventory.fetch("coverage", "legacy-unverified"),
      "observed_conversation_count" => observed_count,
      "full_audit" => inventory["full_audit"],
      "unique_markdown_payload_count" => markdown_payloads.length,
      "completed_conversation_count" => completed_ids.length,
      "pending_conversation_count" => pending.length,
      "archived_conversation_count" => freshness_states.count { |entry| entry["current"] },
      "archived_unresolved_count" => freshness_states.count { |entry| entry["freshness"] == "unresolved" },
      "freshness_tolerance_seconds" => SnapshotArchive::FRESHNESS_TOLERANCE_SECONDS,
      "completed" => completed,
      "legacy_evidence" => legacy_evidence,
      "freshness" => freshness_states,
      "unknown_or_unresolved_count" => freshness_states.count { |entry| entry["state"] != "verified-unchanged" && !entry["selected"] },
      "unresolved_markdown_payloads" => unresolved.map { |payload| unresolved_report(payload, title_index) }
    }

    queue = {
      "schema" => QUEUE_SCHEMA,
      "generated_at" => report.fetch("generated_at"),
      "project_id" => project_id,
      "inventory_file" => report.fetch("inventory_file"),
      "inventory_sha256" => report.fetch("inventory_sha256"),
      "inventory_count" => records.length,
      "inventory_coverage" => inventory.fetch("coverage", "legacy-unverified"),
      "observed_conversation_count" => observed_count,
      "full_audit" => inventory["full_audit"],
      "completed_count" => completed_ids.length,
      "pending_count" => pending.length,
      "pending" => pending.map do |record|
        {
          "id" => record.fetch("id"),
          "title" => record["title"],
          "create_time" => record["create_time"],
          "update_time" => record["update_time"]
        }
      end
    }

    if inventory["schema"] == "adventurefinder-chat-project-inventory/v0.2"
      queue["schema"] = SnapshotArchive::QUEUE_SCHEMA
      queue["account_id"] = inventory.fetch("account_id")
      queue["source"] = inventory.slice("schema", "producer", "checkpoint_sha256", "scan_started_at", "generated_at", "coverage", "full_audit")
        .merge("inventory_sha256" => report.fetch("inventory_sha256"))
      queue["pending"] = pending
      queue = SnapshotArchive.seal(queue)
      SnapshotArchive.queue!(queue)
    end

    validate_state_paths!
    FileUtils.mkdir_p(STATE_DIR)
    ReconcileHelpers.atomic_json(File.join(STATE_DIR, "reconciliation.json"), report)
    ReconcileHelpers.atomic_json(File.join(STATE_DIR, "completed_ids.json"), {
      "schema" => "adventurefinder-chat-completed-ids/v0.1",
      "generated_at" => report.fetch("generated_at"),
      "project_id" => project_id,
      "ids" => completed_ids.keys.sort
    })
    ReconcileHelpers.atomic_json(File.join(STATE_DIR, "pending_ids.json"), queue)
    write_console_runner(queue)
    write_inventory_runner(inventory)

    print_summary(report)
    report
  end

  private

  # Refuse state symlinks before writing generated queues/checkpoints/runners.
  # Fixed filenames stay within STATE_DIR; returns nil or raises ReconcileError.
  def validate_state_paths!
    %w[reconciliation.json completed_ids.json pending_ids.json project_batch_console.js project_inventory_console.js].each do |name|
      current = File.join(STATE_DIR, name)
      loop do
        raise ReconcileError, "state symlink refused" if File.symlink?(current)
        break if current == "/"
        current = File.dirname(current)
      end
    end
    nil
  end

  def write_console_runner(queue)
    runner_path = File.expand_path("project_batch_export.js", __dir__)
    raise ReconcileError, "batch runner missing: #{runner_path}" unless File.file?(runner_path)

    output_path = File.join(STATE_DIR, "project_batch_console.js")
    queue_json = JSON.generate(queue)
    content = <<~JAVASCRIPT
      window.__adventureFinderBatchQueue = #{queue_json};
      #{File.binread(runner_path)}
    JAVASCRIPT
    File.binwrite(output_path, content)
  end

  def newest_inventory
    candidates = Dir.glob(File.join(data_repo, INVENTORY_GLOB))
    candidates.max_by { |path| [File.mtime(path), path] }
  end

  # Return cumulative v0.2 records or legacy full JSON records, normalized to UTC.
  # Reject malformed/duplicate IDs rather than hiding them by raw-page deduplication.
  # Legacy raw pages remain preferred because v0.1 normalized ISO timestamps to null.
  def inventory_records(inventory)
    schema = inventory["schema"]
    if schema == "adventurefinder-chat-project-inventory/v0.2"
      values = inventory["conversations"]
      validate_cumulative_inventory(inventory)
    elsif schema.nil? || schema == "adventurefinder-chat-project-inventory/v0.1"
      raw_pages = inventory["raw_pages"]
      values = if raw_pages.is_a?(Array) && raw_pages.any?
        raw_pages.flat_map do |page|
          raise ReconcileError, "inventory raw page has no items array" unless page.is_a?(Hash) && page["items"].is_a?(Array)
          page["items"]
        end
      else
        inventory["conversations"]
      end
    else
      raise ReconcileError, "unsupported inventory schema"
    end
    raise ReconcileError, "inventory has neither raw_pages nor conversations" unless values.is_a?(Array)

    seen = {}
    values.map do |item|
      raise ReconcileError, "conversation inventory item is not an object" unless item.is_a?(Hash)
      id = item["id"]
      raise ReconcileError, "conversation inventory item missing id" unless id.is_a?(String) && !id.strip.empty?
      raise ReconcileError, "inventory contains duplicate conversation IDs" if seen[id]
      seen[id] = true
      record = item.slice("id", "title")
      if schema == "adventurefinder-chat-project-inventory/v0.2"
        record.merge!(item.slice("create_time_status", "update_time_status", "observed_in_scan", "last_observed_at", "last_full_audit_at"))
      end
      %w[create_time update_time].each do |field|
        normalized = ReconcileHelpers.inventory_timestamp(item[field])
        record[field] = normalized[:value]
      end
      record
    end
  end

  # Validate the explicit cumulative/partial contract before reconciliation writes.
  # Input is parsed JSON; raises ReconcileError on inconsistent counts or provenance.
  # Verify the same checksum as the browser before using or embedding a checkpoint.
  def validate_cumulative_inventory(inventory)
    records = inventory["conversations"]
    pages = inventory["raw_pages"]
    audit = inventory["full_audit"]
    scan_time = inventory["scan_started_at"]
    unless records.is_a?(Array) && pages.is_a?(Array) && pages.any? && audit.is_a?(Hash) &&
        inventory["producer"] == "project_inventory.js/ECT-01" &&
        inventory["account_id"].is_a?(String) && !inventory["account_id"].strip.empty? &&
        inventory["project_id"].is_a?(String) && !inventory["project_id"].strip.empty? &&
        inventory["checkpoint_sha256"].is_a?(String) && /\A[0-9a-f]{64}\z/.match?(inventory["checkpoint_sha256"]) &&
        ReconcileHelpers.inventory_timestamp(scan_time)[:value] == scan_time && scan_time &&
        %w[exhaustive incremental].include?(inventory["coverage"]) &&
        inventory["known_conversation_count"] == records.length && inventory["page_count"] == pages.length
      raise ReconcileError, "invalid cumulative inventory contract"
    end
    checksum = Digest::SHA256.hexdigest(ReconcileHelpers.checkpoint_encoding(inventory.reject { |key, _| key == "checkpoint_sha256" }))
    raise ReconcileError, "inventory checkpoint checksum mismatch" unless checksum == inventory["checkpoint_sha256"]

    observed = records.select { |record| record.is_a?(Hash) && record["observed_in_scan"] == true }
    unless records.all? { |record| record.is_a?(Hash) && [true, false].include?(record["observed_in_scan"]) } &&
        observed.length == inventory["observed_conversation_count"] &&
        observed.all? { |record| record["last_observed_at"] == scan_time }
      raise ReconcileError, "inconsistent cumulative observation counts"
    end
    records.each do |record|
      unless record["id"].is_a?(String) && !record["id"].strip.empty? &&
          ReconcileHelpers.inventory_timestamp(record["last_observed_at"])[:value] == record["last_observed_at"] &&
          record["last_observed_at"] && record["last_observed_at"] <= scan_time
        raise ReconcileError, "invalid cumulative record provenance"
      end
      %w[create_time update_time].each do |field|
        unless %w[valid missing invalid].include?(record["#{field}_status"]) &&
            ReconcileHelpers.inventory_timestamp(record[field])[:value] == record[field] &&
            (!record[field].nil? == (record["#{field}_status"] == "valid"))
          raise ReconcileError, "invalid cumulative normalized timestamp"
        end
      end
    end
    audit_time = audit["started_at"]
    unless audit_time && ReconcileHelpers.inventory_timestamp(audit_time)[:value] == audit_time &&
        audit_time <= scan_time && audit["id"] == audit_time &&
        audit["page_count"].is_a?(Integer) && audit["page_count"].between?(1, 10_000) &&
        audit["observed_count"].is_a?(Integer) && audit["observed_count"] >= 0 &&
        [true, false].include?(audit["ordered"]) && [true, false].include?(audit["timestamps_usable"]) &&
        inventory["watermark"] == scan_time && inventory["overlap_ms"] == 604_800_000 &&
        inventory["audit_interval_ms"] == 604_800_000 && pages.length <= 10_000 &&
        records.count { |record| record["last_full_audit_at"] == audit_time } == audit["observed_count"]
      raise ReconcileError, "invalid cumulative full-audit lineage"
    end
    records.each do |record|
      last_audit = record["last_full_audit_at"]
      unless last_audit.nil? || (ReconcileHelpers.inventory_timestamp(last_audit)[:value] == last_audit && last_audit <= audit_time)
        raise ReconcileError, "invalid cumulative full-audit observation"
      end
    end
    cursors = { "0" => true }
    raw = pages.each_with_index.flat_map do |page, index|
      raise ReconcileError, "malformed cumulative raw page" unless page.is_a?(Hash) && page["items"].is_a?(Array)
      cursor = page["cursor"]
      if (!cursor.nil? && (!cursor.is_a?(String) || cursor.strip.empty? || cursors[cursor])) ||
          (index < pages.length - 1 && cursor.nil?) || (page["items"].empty? && !cursor.nil?)
        raise ReconcileError, "invalid cumulative cursor coverage"
      end
      cursors[cursor] = true unless cursor.nil?
      page["items"]
    end
    raw_ids = raw.map { |item| item.is_a?(Hash) ? item["id"] : nil }
    unless raw_ids.compact.length == raw_ids.length && raw_ids.uniq.length == raw_ids.length &&
        raw_ids.sort == observed.map { |record| record["id"] }.sort
      raise ReconcileError, "cumulative raw IDs disagree with observed records"
    end
    by_id = records.to_h { |record| [record["id"], record] }
    ordered = true
    usable = true
    last_update = nil
    raw.each do |item|
      record = by_id.fetch(item["id"])
      update = ReconcileHelpers.inventory_timestamp(item["update_time"])[:value]
      usable = false unless update
      ordered = false if update && last_update && update > last_update
      last_update = update
      %w[create_time update_time].each do |field|
        normalized = ReconcileHelpers.inventory_timestamp(item[field])
        unless normalized[:value] == record[field] && normalized[:status] == record["#{field}_status"]
          raise ReconcileError, "cumulative raw timestamps disagree with records"
        end
      end
      raise ReconcileError, "cumulative raw title disagrees with records" unless
        (item["title"].is_a?(String) ? item["title"] : nil) == record["title"]
    end
    if inventory["coverage"] == "exhaustive" &&
        (pages.last["cursor"] || audit_time != scan_time || audit["observed_count"] != observed.length ||
         audit["page_count"] != pages.length || audit["ordered"] != ordered || audit["timestamps_usable"] != usable)
      raise ReconcileError, "exhaustive coverage was not exhausted"
    end
    if inventory["coverage"] == "incremental"
      cutoff = inventory["cutoff"]
      unless pages.last["cursor"] && ordered && usable && audit["ordered"] && audit["timestamps_usable"] &&
          cutoff && ReconcileHelpers.inventory_timestamp(cutoff)[:value] == cutoff && last_update && last_update < cutoff &&
          pages.length < 100 && Time.iso8601(scan_time) - Time.iso8601(audit_time) < 604_800
        raise ReconcileError, "unsafe incremental stopping evidence"
      end
    end
  end

  # Embed a saved v0.2 checkpoint and the inventory script for the next daily run.
  # Legacy files start a fresh full scan; file/JSON errors propagate, no archive writes.
  def write_inventory_runner(inventory)
    previous = inventory["schema"] == "adventurefinder-chat-project-inventory/v0.2" ? inventory : nil
    script = File.read(File.expand_path("project_inventory.js", __dir__), encoding: Encoding::UTF_8)
    content = "window.__chatProjectInventoryPrevious = #{JSON.generate(previous)};\n#{script}"
    File.binwrite(File.join(STATE_DIR, "project_inventory_console.js"), content)
  end

  def unique_markdown_payloads
    groups = Hash.new { |hash, key| hash[key] = [] }

    Dir.glob(File.join(data_repo, "*.md")).sort.each do |path|
      groups[ReconcileHelpers.sha256_file(path)] << path
    end

    groups.map do |sha256, paths|
      parsed = paths.map { |path| ReconcileHelpers.parse_export_filename(path) }
      {
        sha256: sha256,
        paths: paths.map { |path| relative_to_data_repo(path) },
        titles: parsed.map { |entry| entry.fetch(:title) }.uniq,
        dates: parsed.map { |entry| entry.fetch(:date) }.compact.uniq
      }
    end.sort_by { |payload| payload.fetch(:paths).first }
  end

  def match_payload(payload, title_index)
    normalized_titles = payload.fetch(:titles).map { |title| ReconcileHelpers.normalize_title(title) }.uniq
    candidates = normalized_titles.flat_map { |title| title_index.fetch(title, []) }
      .uniq { |record| record.fetch("id") }

    return nil if candidates.empty?

    if candidates.length == 1
      return {
        conversation_id: candidates.first.fetch("id"),
        match_reason: "unique-normalized-title"
      }
    end

    date_matches = candidates.select do |record|
      record_dates = ReconcileHelpers.time_date_candidates(record["create_time"])
      !(record_dates & payload.fetch(:dates)).empty?
    end

    return nil unless date_matches.length == 1

    {
      conversation_id: date_matches.first.fetch("id"),
      match_reason: "normalized-title-and-create-date"
    }
  end

  def unresolved_report(payload, title_index)
    candidates = payload.fetch(:titles).flat_map do |title|
      title_index.fetch(ReconcileHelpers.normalize_title(title), [])
    end.uniq { |record| record.fetch("id") }

    {
      "markdown_files" => payload.fetch(:paths),
      "markdown_sha256" => payload.fetch(:sha256),
      "filename_titles" => payload.fetch(:titles),
      "filename_dates" => payload.fetch(:dates),
      "candidate_conversations" => candidates.map do |record|
        {
          "id" => record.fetch("id"),
          "title" => record["title"],
          "create_time" => record["create_time"]
        }
      end
    }
  end

  # Return legacy raw identity evidence for known IDs; never proves freshness or
  # complete ingestion. Raises on malformed JSON or conflicting embedded IDs.
  def raw_capture_ids(inventory_by_id)
    raw_dir = File.join(data_repo, "raw")
    return [] unless Dir.exist?(raw_dir)

    Dir.glob(File.join(raw_dir, "*.json")).filter_map do |path|
      id = File.basename(path, ".json")
      next unless inventory_by_id.key?(id)

      begin
        raw = JSON.parse(File.binread(path))
      rescue JSON::ParserError
        raise ReconcileError, "invalid raw JSON capture: #{path}"
      end

      raise ReconcileError, "raw capture must be an object: #{path}" unless raw.is_a?(Hash)
      %w[id conversation_id].each do |field|
        raise ReconcileError, "raw capture ID mismatch in #{path}" if raw.key?(field) && raw[field] != id
      end

      id
    end
  end

  def markdown_files_for_id(id)
    Dir.glob(File.join(data_repo, "*.md"))
      .select { |path| File.basename(path).include?("[#{id[0, 8]}]") }
      .map { |path| relative_to_data_repo(path) }
      .sort
  end

  def relative_to_data_repo(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(data_repo)).to_s
  rescue ArgumentError
    File.expand_path(path)
  end

  # Print known-ID counts and generated paths from a validated report; returns nil.
  def print_summary(report)
    puts "AdventureFinder export reconciliation"
    puts "Known inventory:   #{report.fetch("inventory_count")} conversations (#{report.fetch("inventory_coverage")})"
    puts "Existing payloads: #{report.fetch("unique_markdown_payload_count")} unique Markdown payloads"
    puts "Snapshot archives: #{report.fetch("archived_conversation_count")} (#{report.fetch("archived_unresolved_count")} unresolved freshness)"
    puts "Freshness verified: #{report.fetch("completed_conversation_count")}"
    puts "Freshness tolerance: #{report.fetch("freshness_tolerance_seconds")} second (listing change detection remains exact)"
    puts "Pending IDs:       #{report.fetch("pending_conversation_count")}"
    puts "Unknown/deferred:  #{report.fetch("unknown_or_unresolved_count", 0)} (inspect freshness states; zero pending need not mean current)"
    puts "Legacy inventory cannot authorize capture; establish a matching ECT-01 v0.2 inventory." if report["inventory_coverage"] == "legacy-unverified"
    puts "Counts cover known IDs only; completion does not establish discovery or content freshness."
    puts "Unresolved files:  #{report.fetch("unresolved_markdown_payloads").length} payloads"
    puts "Unresolved freshness means archived content with unconfirmed listing agreement, not failed ingestion."
    puts "Unresolved files are unmatched legacy root Markdown (including Codex); this is not a missing-chat count."
    pending_reasons = report.fetch("freshness").select { |entry| entry["selected"] }.group_by { |entry| entry["state"] }
    puts "Queue reasons:    #{pending_reasons.map { |reason, entries| "#{reason}=#{entries.length}" }.join(', ')}"
    puts
    puts "Wrote:"
    puts "  #{File.join(STATE_DIR, "reconciliation.json")}"
    puts "  #{File.join(STATE_DIR, "completed_ids.json")}"
    puts "  #{File.join(STATE_DIR, "pending_ids.json")}"
    puts "  #{File.join(STATE_DIR, "project_batch_console.js")}"
    puts "  #{File.join(STATE_DIR, "project_inventory_console.js")}"
  end
end

if $PROGRAM_NAME == __FILE__
  data_repo = ARGV[0] || DEFAULT_DATA_REPO
  inventory_path = ARGV[1]

  begin
    ExportReconciler.new(data_repo: data_repo, inventory_path: inventory_path).run
  rescue ReconcileError, SnapshotArchiveError, Errno::ENOENT, JSON::ParserError => e
    warn "RECONCILIATION FAILED: #{e.message}"
    exit 1
  end
end
