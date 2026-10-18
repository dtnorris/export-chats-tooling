# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "open3"
require "rbconfig"
require_relative "../reconcile_exports"

# Exercise cumulative and historical inventories against isolated synthetic archives.
class ReconcileExportsTest < Minitest::Test
  SCHEMA = "adventurefinder-chat-project-inventory/v0.2"
  AUDIT = "2026-10-10T12:00:00.000Z"
  SCAN = "2026-10-11T12:00:00.000Z"

  # Create an archive and redirect state inside the temporary root; no real data writes.
  def setup
    @root = Dir.mktmpdir("reconcile-test-")
    @data = File.join(@root, "data")
    @state = File.join(@root, "state")
    FileUtils.mkdir_p(@data)
    @original_state = STATE_DIR
    Object.send(:remove_const, :STATE_DIR)
    Object.const_set(:STATE_DIR, @state)
  end

  # Remove only this test's outputs and restore the original constant.
  def teardown
    Object.send(:remove_const, :STATE_DIR)
    Object.const_set(:STATE_DIR, @original_state)
    FileUtils.remove_entry(@root)
  end

  # Sign a JSON-shaped synthetic checkpoint using the documented producer encoding.
  def sign(inventory)
    payload = inventory.reject { |key, _| key == "checkpoint_sha256" }
    inventory.merge("checkpoint_sha256" => Digest::SHA256.hexdigest(ReconcileHelpers.checkpoint_encoding(payload)))
  end

  # Return three known IDs but only one current raw row; all are unarchived by default.
  def cumulative
    records = %w[current old-pending old-completed].map do |id|
      {
        "id" => id, "title" => id, "create_time" => "2026-01-01T00:00:00.125Z",
        "update_time" => "2026-01-01T00:00:00.125Z",
        "create_time_status" => "valid", "update_time_status" => "valid",
        "observed_in_scan" => id == "current",
        "last_observed_at" => id == "current" ? SCAN : AUDIT,
        "last_full_audit_at" => AUDIT
      }
    end
    raw = records.first.slice("id", "title", "create_time", "update_time")
    sign({
      "schema" => SCHEMA, "producer" => "project_inventory.js/ECT-01",
      "project_id" => "g-p-test", "account_id" => "account-test",
      "scan_started_at" => SCAN, "generated_at" => SCAN, "watermark" => SCAN,
      "coverage" => "incremental", "scan_reason" => "daily",
      "overlap_ms" => 604_800_000, "audit_interval_ms" => 604_800_000,
      "cutoff" => "2026-10-03T12:00:00.000Z", "page_count" => 1,
      "known_conversation_count" => 3, "observed_conversation_count" => 1,
      "full_audit" => {
        "id" => AUDIT, "started_at" => AUDIT, "observed_count" => 3,
        "page_count" => 1, "ordered" => true, "timestamps_usable" => true
      },
      "conversations" => records, "raw_pages" => [{ "items" => [raw], "cursor" => "next" }]
    })
  end

  # Reconcile a synthetic manifest; returns the report and leaves outputs in test state.
  def reconcile(inventory)
    path = File.join(@data, "Synthetic Project Inventory.json")
    File.binwrite(path, JSON.generate(inventory))
    report = nil
    capture_io { report = ExportReconciler.new(data_repo: @data, inventory_path: path).run }
    report
  end

  # Read a generated state artifact, raising JSON/file errors if generation failed.
  def state(name)
    JSON.parse(File.binread(File.join(@state, name)))
  end

  def test_partial_raw_pages_keep_every_old_pending_id_and_truthful_totals
    FileUtils.mkdir_p(File.join(@data, "raw"))
    File.binwrite(File.join(@data, "raw", "old-completed.json"), '{"id":"old-completed"}')
    report = reconcile(cumulative)
    assert_equal 3, report["inventory_count"]
    assert_equal 1, report["observed_conversation_count"]
    assert_equal "incremental", report["inventory_coverage"]
    assert_equal 0, report["completed_conversation_count"]
    assert_equal 3, report["pending_conversation_count"]
    assert_equal ["old-completed"], report["legacy_evidence"].map { |entry| entry["id"] }
    assert_equal "unknown-legacy", report["freshness"].find { |entry| entry["id"] == "old-completed" }["state"]
    queue = state("pending_ids.json")
    assert_equal %w[current old-completed old-pending], queue["pending"].map { |record| record["id"] }.sort
    assert_equal 3, queue["inventory_count"]
    assert_equal 1, queue["observed_conversation_count"]
    assert_includes File.binread(File.join(@state, "project_inventory_console.js")), "window.__chatProjectInventoryPrevious = "
    assert_includes File.binread(File.join(@state, "project_inventory_console.js")), SCHEMA
  end

  def test_full_audit_retains_history_without_claiming_it_was_observed
    inventory = cumulative
    inventory["coverage"] = "exhaustive"
    inventory["scan_reason"] = "forced"
    inventory["raw_pages"].first["cursor"] = nil
    inventory["full_audit"].merge!("id" => SCAN, "started_at" => SCAN, "observed_count" => 1)
    inventory["conversations"].first["last_full_audit_at"] = SCAN
    report = reconcile(sign(inventory))
    assert_equal 3, report["inventory_count"]
    assert_equal 1, report["observed_conversation_count"]
    assert_equal 3, report["pending_conversation_count"]
    assert_equal "exhaustive", report["inventory_coverage"]
  end

  def test_corrupt_cumulative_contract_does_not_replace_existing_queue
    reconcile(cumulative)
    original = File.binread(File.join(@state, "pending_ids.json"))
    mutations = [
      ->(inventory) { inventory["known_conversation_count"] = 1 },
      ->(inventory) { inventory["observed_conversation_count"] = 3 },
      ->(inventory) { inventory["raw_pages"].first["items"] << inventory["raw_pages"].first["items"].first },
      ->(inventory) { inventory["conversations"] << inventory["conversations"].last },
      ->(inventory) { inventory["raw_pages"].first["items"].first["title"] = "wrong" },
      ->(inventory) { inventory["raw_pages"].first["cursor"] = "0" },
      ->(inventory) { inventory["coverage"] = "exhaustive" },
      ->(inventory) { inventory["conversations"].last["create_time"] = "bad" },
      ->(inventory) { inventory["full_audit"]["started_at"] = "bad" },
      ->(inventory) { inventory["full_audit"]["observed_count"] = 2 },
      ->(inventory) { inventory["cutoff"] = "2025-01-01T00:00:00.000Z" }
    ]
    mutations.each do |mutate|
      inventory = cumulative
      mutate.call(inventory)
      assert_raises(ReconcileError) { reconcile(sign(inventory)) }
      assert_equal original, File.binread(File.join(@state, "pending_ids.json"))
    end
    inventory = cumulative
    inventory["account_id"] = "corrupted"
    assert_raises(ReconcileError) { reconcile(inventory) }
    assert_equal original, File.binread(File.join(@state, "pending_ids.json"))
  end

  def test_legacy_iso_raw_pages_remain_preferred_and_numeric_seconds_still_match_dates
    inventory = {
      "schema" => "adventurefinder-chat-project-inventory/v0.1",
      "project_id" => "g-p-test", "observed_conversation_count" => 2,
      "conversations" => [{ "id" => "iso", "create_time" => nil }, { "id" => "seconds", "create_time" => nil }],
      "raw_pages" => [{ "items" => [
        { "id" => "iso", "title" => "Same title", "create_time" => "2026-01-02T01:00:00+01:00" },
        { "id" => "seconds", "title" => "Same title", "create_time" => 1_767_225_600 }
      ] }]
    }
    File.binwrite(File.join(@data, "2026-01-02 - Same title.md"), "A unique synthetic Markdown payload")
    report = reconcile(inventory)
    assert_equal ["iso"], report["legacy_evidence"].map { |record| record["id"] }
    assert_empty report["completed"]
    assert_equal 0, report["completed_conversation_count"]
    assert_equal %w[iso seconds], state("pending_ids.json")["pending"].map { |record| record["id"] }.sort
    assert report["freshness"].all? { |entry| entry["state"] == "unknown-legacy-inventory" && !entry["selected"] }
    assert_includes File.binread(File.join(@state, "project_inventory_console.js")), "window.__chatProjectInventoryPrevious = null;"
  end

  def test_legacy_conversations_only_and_empty_inventories
    [[], [{ "id" => "old", "title" => "Known", "create_time" => 0, "update_time" => nil }]].each do |records|
      report = reconcile({ "project_id" => "g-p-test", "conversations" => records })
      assert_equal records.length, report["pending_conversation_count"]
    end
    assert_raises(ReconcileError) do
      reconcile({ "project_id" => "g-p-test", "raw_pages" => [{ "items" => [{ "id" => "same" }, { "id" => "same" }] }] })
    end
    assert_raises(ReconcileError) { reconcile({ "project_id" => "g-p-test", "raw_pages" => [{}] }) }
  end

  def test_supported_timestamp_units_forms_and_invalid_values
    valid = {
      0 => "1970-01-01T00:00:00.000Z",
      0.0004999999999999999 => "1970-01-01T00:00:00.000Z",
      0.0005 => "1970-01-01T00:00:00.001Z", -0.0005 => "1970-01-01T00:00:00.000Z", 1.125 => "1970-01-01T00:00:01.125Z",
      -0.001 => "1969-12-31T23:59:59.999Z", -62_135_596_800 => "0001-01-01T00:00:00.000Z",
      253_402_300_799.999 => "9999-12-31T23:59:59.999Z",
      "2024-02-29T12:34:56Z" => "2024-02-29T12:34:56.000Z",
      "1582-10-10T12:00:00Z" => "1582-10-10T12:00:00.000Z",
      "2026-10-10T14:00:00.1+02:00" => "2026-10-10T12:00:00.100Z",
      "2026-10-10T08:30:00.12-03:30" => "2026-10-10T12:00:00.120Z"
    }
    valid.each do |input, expected|
      assert_equal({ value: expected, status: "valid" }, ReconcileHelpers.inventory_timestamp(input), input.inspect)
    end
    [nil, ""].each do |input|
      assert_equal({ value: nil, status: "missing" }, ReconcileHelpers.inventory_timestamp(input))
    end
    [Float::NAN, Float::INFINITY, -Float::INFINITY, 1e20, -62_135_596_801, 253_402_300_800, true, {}, "1",
     "1500-02-29T12:00:00Z", "2026-02-29T12:00:00Z", "2026-04-31T12:00:00Z", "0000-01-01T00:00:00Z", "2026-10-10",
     "2026-10-10T12:00:00", "2026-10-10T24:00:00Z", "2026-10-10T12:00:60Z",
     "2026-10-10T12:00:00+14:01", "2026-10-10T12:00:00-00:00", "2026-10-10T12:00:00+01:60",
     "2026-10-10T12:00:00.1234Z", " "].each do |input|
      assert_equal({ value: nil, status: "invalid" }, ReconcileHelpers.inventory_timestamp(input), input.inspect)
      assert_empty ReconcileHelpers.time_date_candidates(input)
    end
  end

  def test_ambiguous_invalid_creation_dates_cannot_suppress_pending_ids
    File.binwrite(File.join(@data, "2026-01-01 - Same.md"), "Ambiguous synthetic transcript")
    records = %w[first second].map { |id| { "id" => id, "title" => "Same", "create_time" => "January 1" } }
    report = reconcile({ "project_id" => "g-p-test", "conversations" => records })
    assert_equal 0, report["completed_conversation_count"]
    assert_equal 2, report["pending_conversation_count"]
  end

  def test_cli_runs_in_disposable_tooling_root_and_preserves_archive_bytes
    tooling = File.join(@root, "tooling")
    FileUtils.mkdir_p(tooling)
    %w[reconcile_exports.rb snapshot_archive.rb project_batch_export.js project_inventory.js].each do |name|
      FileUtils.cp(File.expand_path("../#{name}", __dir__), tooling)
    end
    path = File.join(@data, "Synthetic Project Inventory.json")
    File.binwrite(path, JSON.generate(cumulative))
    original = File.binread(path)
    output, errors, status = Open3.capture3(RbConfig.ruby, File.join(tooling, "reconcile_exports.rb"), @data, path)
    assert status.success?, errors
    assert_includes output, "Pending IDs:       3"
    assert_includes output, "known IDs only"
    assert_equal original, File.binread(path)
    assert File.file?(File.join(tooling, ".state", "project_inventory_console.js"))
    refute Dir.exist?(File.join(@data, "raw"))
  end
  # Preserve non-ASCII titles when embedding a full checkpoint into the next browser script.
  def test_unicode_titles_generate_valid_next_inventory_script
    inventory = cumulative
    inventory["conversations"].first["title"] = "Café · 東京 😀"
    inventory["raw_pages"].first["items"].first["title"] = "Café · 東京 😀"
    inventory["conversations"][1]["title"] = "Zoë — São Paulo"

    report = reconcile(sign(inventory))
    generated = File.read(File.join(@state, "project_inventory_console.js"), encoding: Encoding::UTF_8)
    assert_equal 3, report["inventory_count"]
    assert generated.valid_encoding?
    assert_includes generated, "Café · 東京 😀"
    assert_includes generated, "Zoë — São Paulo"
  end
end
