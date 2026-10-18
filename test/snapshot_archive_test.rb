# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../capture_watch"

# Exercise inventory -> queue -> actual browser program -> watcher using only
# synthetic temporary archives. No account requests, real data or wall-clock waits.
class SnapshotArchiveTest < Minitest::Test
  SCAN = "2026-10-10T12:00:00.000Z"
  UPDATE = "2026-10-09T12:00:00.000Z"
  CAPTURE = "2026-10-12T12:00:00.000Z"

  # Isolate state/archive/download writes and preserve the existing state constant.
  def setup
    @root = Dir.mktmpdir("snapshot-test-")
    @data, @downloads, @state = %w[data downloads state].map { |name| File.join(@root, name) }
    FileUtils.mkdir_p([@data, @downloads, @state])
    @original_state = STATE_DIR
    Object.send(:remove_const, :STATE_DIR)
    Object.const_set(:STATE_DIR, @state)
    @archive = SnapshotArchive.new(root: @data, project_id: "g-p-test", account_id: "account-test")
  end

  # Remove synthetic outputs only and restore the process state constant.
  def teardown
    Object.send(:remove_const, :STATE_DIR)
    Object.const_set(:STATE_DIR, @original_state)
    FileUtils.remove_entry(@root)
  end

  # Build exhaustive ECT-01 producer evidence and sign its original typed encoding.
  # Accept raw listing rows and a scan time; returns a trusted synthetic inventory.
  def inventory(rows = [row], scan: SCAN)
    records = rows.map do |entry|
      normalized = entry.slice("id", "title")
      %w[create_time update_time].each do |field|
        time = ReconcileHelpers.inventory_timestamp(entry[field])
        normalized[field] = time[:value]
        normalized["#{field}_status"] = time[:status]
      end
      normalized.merge("observed_in_scan" => true, "last_observed_at" => scan, "last_full_audit_at" => scan)
    end
    value = { "schema" => "adventurefinder-chat-project-inventory/v0.2", "producer" => "project_inventory.js/ECT-01",
      "project_id" => "g-p-test", "account_id" => "account-test", "scan_started_at" => scan, "generated_at" => scan,
      "watermark" => scan, "coverage" => "exhaustive", "scan_reason" => "forced", "overlap_ms" => 604_800_000,
      "audit_interval_ms" => 604_800_000, "cutoff" => nil, "page_count" => 1,
      "known_conversation_count" => rows.length, "observed_conversation_count" => rows.length,
      "conversations" => records, "raw_pages" => [{ "items" => rows, "cursor" => nil }],
      "full_audit" => { "id" => scan, "started_at" => scan, "page_count" => 1, "observed_count" => rows.length,
        "ordered" => rows.map { |entry| ReconcileHelpers.inventory_timestamp(entry["update_time"])[:value] }.compact.each_cons(2).all? { |left, right| left >= right },
        "timestamps_usable" => rows.all? { |entry| ReconcileHelpers.inventory_timestamp(entry["update_time"])[:status] == "valid" } } }
    value.merge("checkpoint_sha256" => Digest::SHA256.hexdigest(ReconcileHelpers.checkpoint_encoding(value)))
  end

  # Return an old conversation's listing row with a recent update, or caller changes.
  def row(id = "old-chat", update: UPDATE)
    { "id" => id, "title" => "Synthetic #{id}", "create_time" => "2020-01-01T00:00:00.000Z", "update_time" => update }
  end

  # Return full raw mapping, including an inactive branch and arbitrary metadata.
  def raw(id = "old-chat", text: "Hello", update: UPDATE, extra: {})
    { "id" => id, "title" => "Synthetic #{id}", "create_time" => 1_577_836_800, "update_time" => update,
      "current_node" => "active", "mapping" => {
        "root" => { "id" => "root", "parent" => nil, "children" => %w[active inactive], "message" => nil },
        "active" => { "id" => "active", "parent" => "root", "children" => [], "message" => {
          "author" => { "role" => "user" }, "content" => { "content_type" => "text", "parts" => [text] } } },
        "inactive" => { "id" => "inactive", "parent" => "root", "children" => [], "message" => {
          "author" => { "role" => "assistant" }, "content" => { "content_type" => "text", "parts" => ["Other branch"] } } }
      }, "source_metadata" => { "preserve" => true } }.merge(extra)
  end

  # Run real reconciliation; return its generated queue/report. Errors propagate.
  def reconcile(value = inventory)
    path = File.join(@data, "Synthetic Project Inventory.json")
    File.binwrite(path, JSON.generate(value))
    report = nil
    capture_io { report = ExportReconciler.new(data_repo: @data, inventory_path: path).run }
    [JSON.parse(File.binread(File.join(@state, "pending_ids.json"))), report]
  end

  # Construct a producer package for focused fault/negative tests without Node cost.
  # Full pipeline tests separately exercise actual browser-derived Markdown/hashes.
  def package(queue, content = raw, started: CAPTURE, markdown: "## Message 1\n\n### User\n\nHello\n", raw_text: nil)
    raw_text ||= JSON.generate(content)
    { "schema" => SnapshotArchive::CAPTURE_SCHEMA, "project_id" => queue["project_id"], "account_id" => queue["account_id"],
      "queue_sha256" => queue["sha256"], "entry" => queue["pending"].find { |entry| entry["id"] == content["id"] },
      "conversation_id" => content["id"], "renderer" => SnapshotArchive::RENDERER, "message_count" => 1,
      "request_started_at" => started, "captured_at" => started, "raw_json" => raw_text,
      "raw_sha256" => Digest::SHA256.hexdigest(raw_text), "markdown" => markdown, "markdown_sha256" => Digest::SHA256.hexdigest(markdown) }
  end

  # Execute the browser harness in one real Node process, returning downloaded JSON.
  # Optional response fixtures test HTTP/stop behavior without account requests.
  def browser(queue, contents, options = {})
    output, errors, status = Open3.capture3("node", File.expand_path("browser_batch_fixture.js", __dir__),
      stdin_data: JSON.generate({ "queue" => queue, "conversations" => contents, "options" => options }))
    assert status.success?, errors
    JSON.parse(output)
  end

  # Write an actual temporary download and run real watcher ingestion. Returns path.
  def watch(text, fault: nil)
    path = File.join(@downloads, "AFCHAT_fixture.json")
    File.binwrite(path, text)
    watcher = CaptureWatch.new(data_repo: @data, download_dir: @downloads, state_dir: @state, fault: fault)
    capture_io { watcher.send(:process_capture!, path) }
    path
  end

  # Read the current pointer or checkpoint; filesystem/JSON failures propagate.
  def read_json(path)
    JSON.parse(File.binread(path))
  end

  # Hash every existing archive file, preserving paths as well as bytes.
  def files
    Dir.glob(File.join(@data, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h do |path|
      [path.delete_prefix(@data + "/"), Digest::SHA256.file(path).hexdigest]
    end
  end

  # Count complete version directories, excluding observations and incoming files.
  def versions
    Dir.glob(File.join(@data, "versions", "old-chat", "*", "version.json"))
  end

  # Exercise browser capture, watcher, unchanged selection and an appended old chat.
  def test_pipeline_preserves_legacy_and_all_earlier_versions
    FileUtils.mkdir_p(File.join(@data, "raw"))
    File.binwrite(File.join(@data, "raw", "old-chat.json"), JSON.pretty_generate(raw))
    File.binwrite(File.join(@data, "2020-01-01 - Synthetic old-chat.md"), "Original legacy bytes\n")
    legacy = files
    queue, report = reconcile
    assert_equal "unknown-legacy", queue["pending"].first["reason"]
    assert_equal 0, report["completed_conversation_count"]
    downloaded = browser(queue, [raw])
    assert_nil downloaded["error"]
    package_text = downloaded["downloads"].fetch(0).fetch("text")
    refute File.exist?(watch(package_text))
    old_version_files = files.select { |name, _| name.include?("/" + SnapshotArchive.digest(raw) + "/") }
    assert_equal 3, old_version_files.length
    assert_empty reconcile.first["pending"]
    update = "2026-10-11T12:00:00.000Z"
    queue, = reconcile(inventory([row(update: update)], scan: "2026-10-12T00:00:00.000Z"))
    assert_equal "updated", queue["pending"].first["reason"]
    changed = raw(update: update)
    changed["mapping"]["active"]["children"] = ["appended"]
    changed["mapping"]["appended"] = { "id" => "appended", "parent" => "active", "children" => [], "message" => {
      "author" => { "role" => "assistant" }, "content" => { "content_type" => "text", "parts" => ["Appended message"] } } }
    changed["current_node"] = "appended"
    watch(browser(queue, [changed], { "now" => "2026-10-13T12:00:00.000Z" })["downloads"].fetch(0).fetch("text"))
    assert_equal 2, versions.length
    legacy.merge(old_version_files).each { |name, hash| assert_equal hash, files[name], name }
    current = @archive.current!("old-chat")
    assert_equal SnapshotArchive.digest(changed), current["version"]
    captured_raw = read_json(File.join(@data, "versions", "old-chat", current["version"], "raw.json"))
    assert_equal changed, captured_raw
    markdown = File.read(File.join(@data, "versions", "old-chat", current["version"], "conversation.md"))
    assert_includes markdown, "Appended message"
    refute_includes markdown, "Other branch"
    assert_empty reconcile(inventory([row(update: update)], scan: "2026-10-12T00:00:00.000Z")).first["pending"]
  end

  # Serialization-only repeats deduplicate; full metadata changes retain new raw.
  def test_digest_scope_serialization_duplicates_and_metadata_changes
    queue, = reconcile
    @archive.ingest(JSON.generate(package(queue)), queue)
    original = files
    reordered = raw.to_a.reverse.to_h
    @archive.ingest(JSON.generate(package(queue, reordered, raw_text: JSON.pretty_generate(reordered))), queue)
    numeric_text = JSON.generate(raw).sub('"create_time":1577836800', '"create_time":1577836800.0')
    @archive.ingest(JSON.generate(package(queue, raw_text: numeric_text)), queue)
    assert_equal 1, versions.length
    assert_equal 3, @archive.observations("old-chat").length
    original.select { |path, _| path.include?(SnapshotArchive.digest(raw)) }.each { |path, hash| assert_equal hash, files[path] }
    metadata_only = raw(extra: { "volatile_provider_metadata" => { "request" => "different" } })
    @archive.ingest(JSON.generate(package(queue, metadata_only, started: "2026-10-13T00:00:00.000Z")), queue)
    assert_equal 2, versions.length
    hashes = versions.map { |path| read_json(path)["markdown_sha256"] }
    assert_equal 1, hashes.uniq.length
  end

  # Advancing listing metadata alone cannot create versions or freshness evidence.
  def test_listing_advance_race_bounded_retry_and_future_reselection
    queue, = reconcile
    @archive.ingest(JSON.generate(package(queue)), queue)
    advanced = "2026-10-11T00:00:00.000Z"
    scan = "2026-10-11T12:00:00.000Z"
    queue, = reconcile(inventory([row(update: advanced)], scan: scan))
    2.times do |index|
      text = JSON.generate(package(queue, started: "2026-10-1#{2 + index}T12:00:00.000Z"))
      @archive.ingest(text, queue)
      @archive.ingest(text, queue) # Exact replay does not consume a retry or version.
    end
    assert_equal 1, versions.length
    assert_equal "unresolved", @archive.current!("old-chat")["freshness"]
    pending, report = reconcile(inventory([row(update: advanced)], scan: scan))
    assert_empty pending["pending"]
    assert_equal "unresolved-wait-inventory", report["freshness"].first["state"]
    assert_equal 1, report["unknown_or_unresolved_count"]
    future, = reconcile(inventory([row(update: advanced)], scan: "2026-10-14T00:00:00.000Z"))
    assert_equal ["old-chat"], future["pending"].map { |entry| entry["id"] }
    changed = raw(update: advanced, text: "Caught up")
    @archive.ingest(JSON.generate(package(future, changed, started: "2026-10-15T00:00:00.000Z")), future)
    assert_equal "verified-as-listed", @archive.current!("old-chat")["freshness"]
  end

  # A fetch racing ahead of listing is retained but cannot advance freshness.
  def test_newer_fetched_timestamp_is_not_a_verified_listing
    queue, = reconcile
    changed = raw(update: "2026-10-12T12:00:01.000Z", text: "Racing update")
    watch(JSON.generate(package(queue, changed)))
    current = @archive.current!("old-chat")
    assert_equal "unresolved", current["freshness"]
    assert_equal changed["update_time"], current.dig("fetched_update", "value")
    assert_empty read_json(File.join(@state, "capture_status.json"))["completed"]
    refute_empty reconcile.first["pending"]
  end

  # Canonical lookup uses capture order, supporting equal/backdated source times
  # and later restoration of previously captured content without duplicate bundles.
  def test_ordering_out_of_order_downloads_and_rollback
    queue, = reconcile
    first = raw
    second = raw(text: "Second", update: UPDATE)
    @archive.ingest(JSON.generate(package(queue, second, started: "2026-10-13T00:00:00.000Z")), queue)
    @archive.ingest(JSON.generate(package(queue, first)), queue)
    assert_equal SnapshotArchive.digest(second), @archive.current!("old-chat")["version"]
    @archive.ingest(JSON.generate(package(queue, first, started: "2026-10-14T00:00:00.000Z")), queue)
    assert_equal SnapshotArchive.digest(first), @archive.current!("old-chat")["version"]
    assert_equal 2, versions.length
    assert_equal 3, @archive.observations("old-chat").length
    assert @archive.version!("old-chat", SnapshotArchive.digest(second))
  end

  # Equal capture/source times have a stable digest tie-breaker; a later backdated
  # provider response still becomes canonical, with unresolved listing freshness.
  def test_equal_capture_ties_and_backdated_source_ordering
    queue, = reconcile
    contents = [raw(text: "Alpha"), raw(text: "Beta")]
    contents.reverse_each { |content| @archive.ingest(JSON.generate(package(queue, content)), queue) }
    assert_equal contents.map { |content| SnapshotArchive.digest(content) }.max, @archive.current!("old-chat")["version"]
    backdated = raw(text: "Restored", update: "2021-01-01T00:00:00.000Z")
    @archive.ingest(JSON.generate(package(queue, backdated, started: "2026-10-14T00:00:00.000Z")), queue)
    assert_equal SnapshotArchive.digest(backdated), @archive.current!("old-chat")["version"]
    assert_equal "unresolved", @archive.current!("old-chat")["freshness"]
  end

  # Legacy files/old statuses stay unknown and bounded; partial absence deletes none.
  def test_unknown_legacy_is_bounded_and_raw_only_never_completes
    rows = 12.times.map { |index| row("legacy-#{index}") }
    FileUtils.mkdir_p(File.join(@data, "raw"))
    rows.each { |entry| File.binwrite(File.join(@data, "raw", entry["id"] + ".json"), JSON.generate({ "id" => entry["id"] })) }
    original = files
    queue, report = reconcile(inventory(rows))
    assert_equal 10, queue["pending"].length
    assert_equal 0, report["completed_conversation_count"]
    assert_equal 2, report["unknown_or_unresolved_count"]
    File.binwrite(File.join(@state, "capture_status.json"), JSON.generate({ "completed" => { "legacy-0" => { "raw_path" => "raw/legacy-0.json" } } }))
    CaptureWatch.new(data_repo: @data, download_dir: @downloads, state_dir: @state)
    assert_empty read_json(File.join(@state, "capture_status.json"))["completed"]
    reconcile(inventory([]))
    original.each { |name, hash| assert_equal hash, files[name] }
  end

  # Legacy inventories retain historical identity evidence but cannot classify
  # raw-only captures as complete or authorize the bound versioned capture lane.
  def test_legacy_inventory_never_promotes_raw_only_files_to_completed
    FileUtils.mkdir_p(File.join(@data, "raw"))
    path = File.join(@data, "raw", "old-chat.json")
    File.binwrite(path, JSON.generate({ "id" => "old-chat" }))
    hash = Digest::SHA256.file(path).hexdigest
    queue, report = reconcile({ "schema" => "adventurefinder-chat-project-inventory/v0.1",
      "project_id" => "g-p-test", "conversations" => [row] })
    assert_equal 0, report["completed_conversation_count"]
    assert_equal ["old-chat"], report["legacy_evidence"].map { |entry| entry["id"] }
    assert_equal "unknown-legacy-inventory", report["freshness"].first["state"]
    assert_raises(SnapshotArchiveError) { SnapshotArchive.queue!(queue) }
    assert_equal hash, Digest::SHA256.file(path).hexdigest
  end

  # A partial ECT-01 scan keeps unobserved history and can skip previously verified
  # unchanged captures without creating an alternative pagination contract.
  def test_partial_inventory_retains_cumulative_history_without_archive_mutation
    update = "2026-01-01T00:00:00.000Z"
    rows = [row("first", update: update), row("second", update: update)]
    full = inventory(rows)
    queue, = reconcile(full)
    browser(queue, rows.map { |entry| raw(entry["id"], update: update) })["downloads"].each { |download| watch(download["text"]) }
    original = files.reject { |name, _| name.end_with?("Project Inventory.json") }
    partial = JSON.parse(JSON.generate(full))
    scan = "2026-10-11T12:00:00.000Z"
    partial.merge!("scan_started_at" => scan, "generated_at" => scan, "watermark" => scan,
      "coverage" => "incremental", "scan_reason" => "daily", "cutoff" => "2026-10-03T12:00:00.000Z",
      "observed_conversation_count" => 1, "raw_pages" => [{ "items" => [rows.first], "cursor" => "next" }])
    partial["conversations"].first["last_observed_at"] = scan
    partial["conversations"].last["observed_in_scan"] = false
    partial.delete("checkpoint_sha256")
    partial["checkpoint_sha256"] = Digest::SHA256.hexdigest(ReconcileHelpers.checkpoint_encoding(partial))
    queue, report = reconcile(partial)
    assert_empty queue["pending"]
    assert_equal 2, report["completed_conversation_count"]
    assert_equal original, files.reject { |name, _| name.end_with?("Project Inventory.json") }
  end

  # Missing/invalid source times remain explicit and recheck only on later audits.
  def test_unusable_source_times_do_not_refetch_daily
    [nil, "invalid"].each do |update|
      FileUtils.rm_rf(File.join(@data, "versions"))
      queue, = reconcile(inventory([row(update: update)]))
      @archive.ingest(JSON.generate(package(queue, raw(update: update))), queue)
      pending, report = reconcile(inventory([row(update: update)]))
      assert_empty pending["pending"]
      assert_equal "unknown-wait-audit", report["freshness"].first["state"]
    end
    queue, = reconcile(inventory([row(update: nil)], scan: "2026-10-14T00:00:00.000Z"))
    assert_equal "unknown-audit", queue["pending"].first["reason"]
  end

  # Reject bad capture metadata/identity/hashes before any archive mutation.
  def test_negative_capture_preconditions_leave_all_files_untouched
    queue, = reconcile
    valid = package(queue)
    mutations = [
      ->(value) { value["schema"] = "old" }, ->(value) { value["account_id"] = "other" },
      ->(value) { value["project_id"] = "g-p-other" }, ->(value) { value["conversation_id"] = "../escape" },
      ->(value) { value.delete("conversation_id") }, ->(value) { value["queue_sha256"] = "0" * 64 },
      ->(value) { value["entry"]["listing"]["update_time"] = CAPTURE },
      ->(value) { value["captured_at"] = "2026-02-30T00:00:00.000Z" },
      ->(value) { value["request_started_at"] = "2026-10-13T00:00:00.000Z" },
      ->(value) { value["message_count"] = 0 }, ->(value) { value["markdown_sha256"] = "0" * 64 },
      ->(value) { value["raw_sha256"] = "0" * 64 }, ->(value) { value["markdown"] = "" },
      ->(value) { value["raw_json"] = "[]"; value["raw_sha256"] = Digest::SHA256.hexdigest("[]") }
    ]
    mutations.each do |mutate|
      value = JSON.parse(JSON.generate(valid))
      mutate.call(value)
      original = files
      assert_raises(SnapshotArchiveError) { @archive.ingest(JSON.generate(value), queue) }
      assert_equal original, files
    end
    [{}, raw.merge("conversation_id" => "conflict"), raw.merge("account_id" => "wrong"),
     raw.merge("project_id" => "g-p-wrong"), raw.reject { |key, _| key == "id" },
     raw.merge("current_node" => "absent"), raw.merge("mapping" => []),
     raw.merge("mapping" => { "active" => { "id" => "active", "parent" => "active", "message" => nil } })].each do |bad_raw|
      value = package(queue)
      value["raw_json"] = JSON.generate(bad_raw)
      value["raw_sha256"] = Digest::SHA256.hexdigest(value["raw_json"])
      assert_raises(SnapshotArchiveError) { @archive.ingest(JSON.generate(value), queue) }
      assert_empty files.reject { |name, _| name.end_with?("Project Inventory.json") }
    end
    [JSON.generate(raw).sub('"id":"old-chat"', '"id":"conflict","id":"old-chat"'),
     JSON.generate(raw).sub('"create_time":1577836800', '"create_time":9007199254740993'),
     JSON.generate(raw).sub('"create_time":1577836800', '"create_time":1e400')].each do |ambiguous_raw|
      value = package(queue, raw_text: ambiguous_raw)
      original = files
      assert_raises(SnapshotArchiveError, JSON::ParserError) { @archive.ingest(JSON.generate(value), queue) }
      assert_equal original, files
    end
  end

  # Queue integrity/binding and unsafe identities fail even before watcher startup.
  def test_negative_queue_metadata
    queue, = reconcile
    queue["account_id"] = "corrupt"
    assert_raises(SnapshotArchiveError) { SnapshotArchive.queue!(queue) }
    queue = SnapshotArchive.seal(queue)
    queue["pending"].first["listing"]["update_time"] = "bad"
    assert_raises(SnapshotArchiveError) { SnapshotArchive.queue!(SnapshotArchive.seal(queue)) }
    queue["pending"].first["id"] = "../../escape"
    assert_raises(SnapshotArchiveError) { SnapshotArchive.queue!(SnapshotArchive.seal(queue)) }
    assert_empty files.reject { |name, _| name.end_with?("Project Inventory.json") }
  end

  # Corrupt/incomplete immutable metadata and conflicting derived bytes fail closed.
  def test_tampered_incomplete_metadata_and_markdown_hash_conflicts
    queue, = reconcile
    text = JSON.generate(package(queue))
    @archive.ingest(text, queue)
    conflict = package(queue, markdown: "Different rendering")
    original = files
    assert_raises(SnapshotArchiveError) { @archive.ingest(JSON.generate(conflict), queue) }
    assert_equal original, files
    version_path = versions.first
    original_version = File.binread(version_path)
    ["{}", JSON.generate(SnapshotArchive.seal({ "schema" => SnapshotArchive::SCHEMA }))].each do |bad|
      File.binwrite(version_path, bad)
      assert_raises(SnapshotArchiveError) { @archive.ingest(text, queue) }
    end
    File.binwrite(version_path, original_version)
    markdown_path = File.join(File.dirname(version_path), "conversation.md")
    original_markdown = File.binread(markdown_path)
    File.unlink(markdown_path)
    assert_raises(SnapshotArchiveError) { @archive.current!("old-chat") }
    File.binwrite(markdown_path, original_markdown)
    index_path = File.join(@data, "versions", "old-chat", "current.json")
    original_index = File.binread(index_path)
    File.binwrite(index_path, "{}")
    assert_raises(SnapshotArchiveError) { @archive.current!("old-chat", repair: true) }
    File.binwrite(index_path, original_index)
    assert_raises(SnapshotArchiveError) { SnapshotArchive.new(root: @data, project_id: "g-p-other", account_id: "account-test") }
    receipt_path = Dir.glob(File.join(@data, "versions", "old-chat", "observations", "*.json")).first
    receipt = read_json(receipt_path)
    File.binwrite(receipt_path, JSON.generate(SnapshotArchive.seal(receipt.reject { |key, _| key == "source" })))
    assert_raises(SnapshotArchiveError) { @archive.current!("old-chat") }
  end

  # Simulate an otherwise infeasible digest collision: distinct raw structures
  # sharing a version key must fail before writes, preserving original evidence.
  def test_content_digest_collision_is_not_mistaken_for_a_duplicate
    queue, = reconcile
    @archive.ingest(JSON.generate(package(queue)), queue)
    original = files
    version = SnapshotArchive.digest(raw)
    digest = SnapshotArchive.method(:digest)
    collision = ->(value) { value.is_a?(Hash) && value.key?("mapping") ? version : digest.call(value) }
    SnapshotArchive.stub(:digest, collision) do
      assert_raises(SnapshotArchiveError) { @archive.ingest(JSON.generate(package(queue, raw(text: "Different source"))), queue) }
    end
    assert_equal original, files
  end

  # Path traversal, root/subdirectory symlinks and download links never write out.
  def test_symlinks_and_traversal
    queue, = reconcile
    outside = File.join(@root, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(@data, "versions"))
    assert_raises(SnapshotArchiveError) { @archive.ingest(JSON.generate(package(queue)), queue) }
    assert_empty Dir.children(outside)
    assert_raises(SnapshotArchiveError) { @archive.path!("../outside") }
    assert_raises(SnapshotArchiveError) { @archive.path!("/outside") }
    File.unlink(File.join(@data, "versions"))
    text = JSON.generate(package(queue))
    stage = File.join(@data, "versions", ".incoming", Digest::SHA256.hexdigest(text))
    FileUtils.mkdir_p(stage)
    target = File.join(outside, "raw.json")
    File.binwrite(target, "private")
    File.symlink(target, File.join(stage, "raw.json"))
    original = files
    assert_raises(SnapshotArchiveError) { @archive.ingest(text, queue) }
    assert_equal original, files
    assert_equal "private", File.binread(target)
    linked = File.join(@downloads, "AFCHAT_link.json")
    File.symlink(target, linked)
    watcher = CaptureWatch.new(data_repo: @data, download_dir: @downloads, state_dir: @state)
    assert_raises(CaptureWatchError) { watcher.send(:process_capture!, linked) }
  end

  # Rejected packages survive watcher processing and can be replayed with the
  # original valid queue. No stale checkpoint or raw-only file completes them.
  def test_rejected_and_stale_queue_downloads_remain_recoverable
    original_queue, = reconcile
    text = JSON.generate(package(original_queue))
    reconcile(inventory([row(update: "2026-10-11T00:00:00.000Z")]))
    assert_raises(SnapshotArchiveError) { watch(text) }
    path = File.join(@downloads, "AFCHAT_fixture.json")
    assert File.exist?(path)
    assert_empty read_json(File.join(@state, "capture_status.json"))["completed"]
    assert_empty versions
    File.binwrite(File.join(@state, "pending_ids.json"), JSON.generate(original_queue))
    watcher = CaptureWatch.new(data_repo: @data, download_dir: @downloads, state_dir: @state)
    capture_io { watcher.send(:process_capture!, path) }
    refute File.exist?(path)
    File.binwrite(path, '{"schema":"malformed"}')
    capture_io { watcher.send(:scan_once); watcher.send(:scan_once) }
    assert File.exist?(path)
    assert_equal 1, versions.length
  end

  # Existing non-directory destinations and unexpected stage files fail before
  # binding, lock or snapshot writes; malformed evidence is retained for inspection.
  def test_conflicting_destination_types_and_staged_files
    queue, = reconcile
    text = JSON.generate(package(queue))
    FileUtils.mkdir_p(File.join(@data, "versions"))
    blocked = File.join(@data, "versions", "old-chat")
    File.binwrite(blocked, "not a directory")
    original = files
    assert_raises(SnapshotArchiveError) { @archive.ingest(text, queue) }
    assert_equal original, files
    File.unlink(blocked)
    stage = File.join(@data, "versions", ".incoming", Digest::SHA256.hexdigest(text))
    FileUtils.mkdir_p(stage)
    File.binwrite(File.join(stage, "unexpected.tmp"), "retain interrupted evidence")
    original = files
    assert_raises(SnapshotArchiveError) { @archive.ingest(text, queue) }
    assert_equal original, files
  end

  # Fault every durable write boundary. Restart replays the same download, repairs
  # missing indexes/checkpoints and yields exactly one complete version/receipt.
  def test_interruption_recovery_at_every_write_boundary
    steps = %w[raw markdown version install observation index checkpoint].flat_map { |name| ["before_#{name}", "after_#{name}"] }
    steps.each do |step|
      FileUtils.rm_rf(File.join(@data, "versions"))
      initial_queue, = reconcile
      @archive.ingest(JSON.generate(package(initial_queue)), initial_queue)
      original = files.select { |name, _| name.include?("/" + SnapshotArchive.digest(raw) + "/") }
      updated_at = "2026-10-11T00:00:00.000Z"
      queue, = reconcile(inventory([row(update: updated_at)]))
      text = JSON.generate(package(queue, raw(text: "After interruption", update: updated_at), started: "2026-10-13T00:00:00.000Z"))
      path = File.join(@downloads, "AFCHAT_fixture.json")
      fault = ->(boundary) { raise Interrupt, boundary if boundary == step }
      assert_raises(Interrupt, step) { watch(text, fault: fault) }
      assert File.file?(path), step
      original.each { |name, hash| assert_equal hash, files[name], step }
      watcher = CaptureWatch.new(data_repo: @data, download_dir: @downloads, state_dir: @state)
      capture_io { watcher.send(:process_capture!, path) }
      refute File.exist?(path), step
      assert_equal 2, versions.length, step
      assert_equal 2, @archive.observations("old-chat").length, step
      assert @archive.current!("old-chat"), step
      assert_equal ["old-chat"], read_json(File.join(@state, "capture_status.json"))["completed"].keys
    end
  end

  # Exercise existing rate controls and sequential stop/resume without real waits.
  def test_browser_rate_limit_stop_and_resume
    queue, = reconcile(inventory([row("first"), row("second")]))
    result = browser(queue, [{ "status" => 429, "retryAfter" => "240" }, raw("first"), raw("second")])
    assert_nil result["error"]
    assert_includes result["delays"], 240_000
    assert_includes result["delays"], 60_000
    assert_equal 2, result["downloads"].length
    assert_equal 4, result["requests"].length # session, retry, two successful requests
    result["downloads"].each { |download| watch(download["text"]) }
    assert_empty reconcile(inventory([row("first"), row("second")])).first["pending"]
    stopped = browser(queue, [raw("first")], { "stopAfterDownload" => true })
    assert_equal 1, stopped["downloads"].length
    refute stopped["running"]
    cooling = browser(queue, [{ "status" => 429 }], { "stopOnWait" => 180_000 })
    assert_empty cooling["downloads"]
    assert_equal 2, cooling["requests"].length
    wrong = browser(queue, [], { "account" => "wrong" })
    assert_match(/account/, wrong["error"])
    assert_equal 1, wrong["requests"].length
    dated = browser(queue, [{ "status" => 429, "retryAfter" => "Mon, 12 Oct 2026 12:05:00 GMT" }, raw("first"), raw("second")])
    assert_includes dated["delays"], 300_000
    refused = browser(queue, [raw("first").merge("conversation_id" => "conflict"), raw("second")])
    assert_equal 1, refused["state"]["extractionFailures"]
    assert_equal 1, refused["downloads"].length
    aborted = browser(queue, [{ "status" => 401 }])
    assert_match(/401/, aborted["error"])
    assert_empty aborted["downloads"]
  end
end
