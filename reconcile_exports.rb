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

  def time_date_candidates(value)
    return [] if value.nil? || value == ""

    time =
      case value
      when Numeric
        Time.at(value).utc
      when String
        Time.parse(value)
      else
        return []
      end

    [
      time.utc.strftime("%Y-%m-%d"),
      time.getlocal.strftime("%Y-%m-%d")
    ].uniq
  rescue ArgumentError, RangeError
    []
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

class ExportReconciler
  include ReconcileHelpers

  attr_reader :data_repo, :inventory_path

  def initialize(data_repo:, inventory_path: nil)
    @data_repo = File.expand_path(data_repo)
    raise ReconcileError, "data repo does not exist: #{@data_repo}" unless Dir.exist?(@data_repo)

    @inventory_path = inventory_path ? File.expand_path(inventory_path) : newest_inventory
    raise ReconcileError, "inventory file not found" unless @inventory_path && File.file?(@inventory_path)
  end

  def run
    inventory = JSON.parse(File.binread(inventory_path))
    project_id = inventory.fetch("project_id")
    records = inventory_records(inventory)
    inventory_by_id = records.to_h { |record| [record.fetch("id"), record] }

    if inventory_by_id.length != records.length
      raise ReconcileError, "inventory contains duplicate conversation IDs"
    end

    observed_count = inventory["observed_conversation_count"]
    if observed_count && observed_count != records.length
      raise ReconcileError,
        "inventory observed count #{observed_count} does not match #{records.length} unique records"
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

    report = {
      "schema" => RECONCILIATION_SCHEMA,
      "generated_at" => Time.now.utc.iso8601,
      "data_repo" => data_repo,
      "inventory_file" => relative_to_data_repo(inventory_path),
      "inventory_sha256" => ReconcileHelpers.sha256_file(inventory_path),
      "project_id" => project_id,
      "inventory_count" => records.length,
      "unique_markdown_payload_count" => markdown_payloads.length,
      "completed_conversation_count" => completed_ids.length,
      "pending_conversation_count" => pending.length,
      "completed" => completed,
      "unresolved_markdown_payloads" => unresolved.map { |payload| unresolved_report(payload, title_index) }
    }

    queue = {
      "schema" => QUEUE_SCHEMA,
      "generated_at" => report.fetch("generated_at"),
      "project_id" => project_id,
      "inventory_file" => report.fetch("inventory_file"),
      "inventory_sha256" => report.fetch("inventory_sha256"),
      "inventory_count" => records.length,
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

    print_summary(report)
    report
  end

  private

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

  def inventory_records(inventory)
    raw_pages = inventory["raw_pages"]
    if raw_pages.is_a?(Array) && raw_pages.any?
      items = raw_pages.flat_map do |page|
        values = page.is_a?(Hash) ? page["items"] : nil
        values.is_a?(Array) ? values : []
      end

      by_id = {}
      items.each do |item|
        next unless item.is_a?(Hash)
        id = item["id"]
        raise ReconcileError, "inventory item missing id" unless id.is_a?(String) && !id.empty?

        by_id[id] ||= {
          "id" => id,
          "title" => item["title"],
          "create_time" => item["create_time"],
          "update_time" => item["update_time"]
        }
      end
      return by_id.values
    end

    values = inventory["conversations"]
    raise ReconcileError, "inventory has neither raw_pages nor conversations" unless values.is_a?(Array)

    values.map do |item|
      raise ReconcileError, "conversation inventory item is not an object" unless item.is_a?(Hash)
      id = item["id"]
      raise ReconcileError, "conversation inventory item missing id" unless id.is_a?(String) && !id.empty?
      item.slice("id", "title", "create_time", "update_time")
    end
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

      embedded_id = raw["id"] || raw["conversation_id"]
      if embedded_id && embedded_id != id
        raise ReconcileError, "raw capture ID mismatch in #{path}: #{embedded_id.inspect} != #{id.inspect}"
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

  def print_summary(report)
    puts "AdventureFinder export reconciliation"
    puts "Inventory:        #{report.fetch("inventory_count")} conversations"
    puts "Existing payloads: #{report.fetch("unique_markdown_payload_count")} unique Markdown payloads"
    puts "Completed IDs:     #{report.fetch("completed_conversation_count")}"
    puts "Pending IDs:       #{report.fetch("pending_conversation_count")}"
    puts "Unresolved files:  #{report.fetch("unresolved_markdown_payloads").length} payloads"
    puts
    puts "Wrote:"
    puts "  #{File.join(STATE_DIR, "reconciliation.json")}"
    puts "  #{File.join(STATE_DIR, "completed_ids.json")}"
    puts "  #{File.join(STATE_DIR, "pending_ids.json")}"
    puts "  #{File.join(STATE_DIR, "project_batch_console.js")}"
  end
end

if $PROGRAM_NAME == __FILE__
  data_repo = ARGV[0] || DEFAULT_DATA_REPO
  inventory_path = ARGV[1]

  begin
    ExportReconciler.new(data_repo: data_repo, inventory_path: inventory_path).run
  rescue ReconcileError, Errno::ENOENT, JSON::ParserError => e
    warn "RECONCILIATION FAILED: #{e.message}"
    exit 1
  end
end
