# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../capture_watch"

# Exercise watcher polling and CLI behavior with temporary, synthetic v0.2
# queues/packages only. No real Downloads, tooling state or archive is accessed.
class CaptureWatchTest < Minitest::Test
  SCAN = "2026-10-10T12:00:00.000Z"
  UPDATE = "2026-10-09T12:00:00.000Z"
  CAPTURE = "2026-10-12T12:00:00.000Z"

  # Copy CLI dependencies and isolate all mutable paths; filesystem errors fail.
  def setup
    @root = File.realpath(Dir.mktmpdir("capture-watch-test-"))
    @data, @downloads, @tooling = %w[data downloads tooling].map { |name| File.join(@root, name) }
    @state = File.join(@tooling, ".state")
    FileUtils.mkdir_p([@data, @downloads, @state])
    %w[capture_watch.rb reconcile_exports.rb snapshot_archive.rb].each do |name|
      FileUtils.cp(File.expand_path("../#{name}", __dir__), @tooling)
    end
    write_queue
  end

  # Remove only the synthetic fixture tree; child processes are reaped by cli.
  def teardown
    FileUtils.remove_entry(@root)
  end

  # Seal and persist a minimal trusted queue with the supplied IDs; returns it.
  # Invalid fixture construction raises through the normal queue validator.
  def write_queue(ids = ["chat"])
    entries = ids.map do |id|
      { "id" => id, "listing" => { "id" => id, "title" => "Synthetic #{id}",
        "create_time" => UPDATE, "update_time" => UPDATE,
        "create_time_status" => "valid", "update_time_status" => "valid", "last_observed_at" => SCAN } }
    end
    @queue = SnapshotArchive.seal({ "schema" => SnapshotArchive::QUEUE_SCHEMA,
      "project_id" => "g-p-test", "account_id" => "account-test", "pending" => entries,
      "source" => { "schema" => "adventurefinder-chat-project-inventory/v0.2",
        "producer" => "project_inventory.js/ECT-01", "coverage" => "exhaustive",
        "checkpoint_sha256" => "a" * 64, "inventory_sha256" => "b" * 64,
        "scan_started_at" => SCAN, "generated_at" => SCAN,
        "full_audit" => { "id" => SCAN, "started_at" => SCAN } } })
    SnapshotArchive.queue!(@queue)
    File.binwrite(File.join(@state, "pending_ids.json"), JSON.generate(@queue))
    @queue
  end

  # Build a full synthetic package for an ID; out-of-queue IDs remain unauthorized.
  # Return a Hash with hashes of its raw/Markdown bytes; no filesystem mutation.
  def package(id = "chat")
    raw = { "id" => id, "update_time" => UPDATE, "current_node" => "root",
      "mapping" => { "root" => { "id" => "root", "parent" => nil, "children" => [],
        "message" => { "author" => { "role" => "user" },
          "content" => { "content_type" => "text", "parts" => ["Synthetic hello"] } } } } }
    raw_text = JSON.generate(raw)
    markdown = "## Message 1\n\n### User\n\nSynthetic hello\n"
    { "schema" => SnapshotArchive::CAPTURE_SCHEMA, "project_id" => @queue["project_id"],
      "account_id" => @queue["account_id"], "queue_sha256" => @queue["sha256"],
      "conversation_id" => id, "entry" => @queue["pending"].find { |entry| entry["id"] == id },
      "renderer" => SnapshotArchive::RENDERER, "request_started_at" => CAPTURE, "captured_at" => CAPTURE,
      "message_count" => 1, "raw_json" => raw_text, "raw_sha256" => Digest::SHA256.hexdigest(raw_text),
      "markdown" => markdown, "markdown_sha256" => Digest::SHA256.hexdigest(markdown) }
  end

  # Write a named synthetic download; return its path, propagating write errors.
  def download(name, text)
    path = File.join(@downloads, "AFCHAT_#{name}.json")
    File.binwrite(path, text)
    path
  end

  # Construct the real watcher against fixture paths; initialization errors escape.
  def watcher(once: false)
    CaptureWatch.new(data_repo: @data, download_dir: @downloads, state_dir: @state, once: once)
  end

  # Run a bounded number of actual scans, returning stdout/stderr captured by Minitest.
  # Unexpected watcher errors escape; this does not replace validation or ingestion.
  def scans(instance, count = 6)
    capture_io { count.times { instance.send(:scan_once) } }
  end

  # Snapshot file bytes and metadata without reading content (which changes atime).
  # Call with a directory; returns path => [size, mtime, ctime, inode, mode, atime].
  def metadata(directory)
    Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h do |path|
      stat = File.stat(path)
      [path, [stat.size, stat.mtime, stat.ctime, stat.ino, stat.mode, stat.atime]]
    end
  end

  # Snapshot file bytes including hidden staged files; returns relative paths/bytes.
  # Filesystem failures propagate instead of masking a mutation in assertions.
  def files(directory)
    Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h do |path|
      [path.delete_prefix(directory + "/"), File.binread(path)]
    end
  end

  # Read the synthetic checkpoint as JSON; parse and filesystem errors escape.
  def status
    JSON.parse(File.binread(File.join(@state, "capture_status.json")))
  end

  # Run a copied CLI with a finite join deadline, draining output concurrently.
  # Return stdout, stderr, status and timeout flag; terminate only this test child.
  # Spawn/read errors propagate; ensure always terminates and reaps a live child.
  def cli(once: false, limit: 2.0, data: @data, downloads: @downloads)
    args = [RbConfig.ruby, File.join(@tooling, "capture_watch.rb"), data, downloads]
    args << "--once" if once
    Open3.popen3(*args) do |input, output, errors, child|
      input.close
      readers = [output, errors].map { |stream| Thread.new { stream.read } }
      timed_out = !child.join(limit)
      if timed_out
        Process.kill("TERM", child.pid) if child.alive?
        Process.kill("KILL", child.pid) if !child.join(1) && child.alive?
      end
      [readers[0].value, readers[1].value, child.value, timed_out]
    ensure
      if child&.alive?
        Process.kill("KILL", child.pid)
        child.join
      end
    end
  end

  # A1: prove no scan/sleep call, then verify the actual CLI and untouched leftovers.
  def test_empty_initial_queue_exits_without_scanning_or_sleeping
    leftover = package("outside")
    write_queue([])
    download("outside", JSON.generate(leftover))
    download("invalid", "{invalid JSON")
    File.binwrite(File.join(@data, "keep.md"), "existing synthetic archive")
    archive = files(@data)
    downloads = files(@downloads)
    original_metadata = metadata(@downloads)
    instance = watcher
    instance.stub(:scan_once, -> { flunk "empty continuous watcher scanned" }) do
      instance.stub(:sleep, ->(*) { flunk "empty continuous watcher slept" }) do
        output, errors = capture_io { instance.run }
        assert_match(/queue empty.*complete/i, output)
        assert_empty errors
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, errors, result, timed_out = cli
    refute timed_out, "initially empty CLI did not finish within two seconds"
    assert result.success?, errors
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<=, 2.0
    assert_match(/queue empty.*complete/i, output)
    assert_empty errors
    assert_equal original_metadata, metadata(@downloads)
    assert_equal downloads, files(@downloads)
    assert_equal archive, files(@data)
    assert_empty status["completed"]
    assert_empty status["ingested"]
  end

  # A2: startup failures must not become empty success or mutate capture evidence.
  def test_invalid_startup_state_fails_cli_without_archive_or_download_mutation
    write_queue([])
    queue_text = File.binread(File.join(@state, "pending_ids.json"))
    download("invalid", "{invalid JSON")
    archive, downloads = files(@data), files(@downloads)
    cases = ["missing queue", "malformed queue", "missing fields", "missing archive", "missing downloads",
      "malformed status", "status shape", "other project", "other account", "bad checksum"]
    cases.each do |name|
      File.binwrite(File.join(@state, "pending_ids.json"), queue_text)
      status_path = File.join(@state, "capture_status.json")
      FileUtils.rm_f(status_path)
      data, download_dir = @data, @downloads
      case name
      when "missing queue" then File.delete(File.join(@state, "pending_ids.json"))
      when "malformed queue" then File.binwrite(File.join(@state, "pending_ids.json"), "{")
      when "missing fields"
        File.binwrite(File.join(@state, "pending_ids.json"), JSON.generate(SnapshotArchive.seal({ "pending" => [] })))
      when "missing archive" then data = File.join(@root, "absent-data")
      when "missing downloads" then download_dir = File.join(@root, "absent-downloads")
      when "malformed status" then File.binwrite(status_path, "{")
      when "status shape" then File.binwrite(status_path, JSON.generate({ "project_id" => "g-p-test", "completed" => [] }))
      when "other project" then File.binwrite(status_path, JSON.generate({ "project_id" => "g-p-other" }))
      when "other account"
        File.binwrite(status_path, JSON.generate({ "project_id" => "g-p-test", "account_id" => "other" }))
      when "bad checksum"
        File.binwrite(status_path, JSON.generate({ "project_id" => "g-p-test", "sha256" => "0" * 64 }))
      end
      prior_status = File.binread(status_path) if File.exist?(status_path)
      output, errors, result, timed_out = cli(data: data, downloads: download_dir)
      refute timed_out, name
      refute result.success?, name
      assert_includes errors, "CAPTURE WATCH FAILED:", name
      refute_match(/queue empty.*complete/i, output, name)
      assert_equal archive, files(@data), name
      assert_equal downloads, files(@downloads), name
      assert_equal prior_status, File.binread(status_path), name if File.exist?(status_path)
    end
  end

  # Legacy status stays compatible, but its reported totals cannot remove pending
  # entries. The initially nonempty watcher must continue across polling cycles.
  def test_legacy_status_is_rebuilt_without_trusting_completed_totals
    File.binwrite(File.join(@state, "capture_status.json"), JSON.generate({
      "schema" => "adventurefinder-chat-capture-status/v0.2", "project_id" => "g-p-test",
      "completed" => { "chat" => { "reported" => true } } }))
    instance = watcher
    assert_empty status["completed"]
    calls = 0
    instance.stub(:scan_once, -> { calls += 1; raise Interrupt if calls == 3 }) do
      instance.stub(:sleep, ->(*) {}) { capture_io { instance.run } }
    end
    assert_equal 3, calls
  end

  # Preserve ECT-02's rebuild of unbound legacy derived status; it grants no trust.
  def test_unbound_legacy_status_is_rebuilt_from_archive_evidence
    File.binwrite(File.join(@state, "capture_status.json"), JSON.generate({
      "completed" => { "chat" => { "raw_path" => "raw/chat.json" } } }))
    watcher
    assert_equal "g-p-test", status["project_id"]
    assert_empty status["completed"]
    assert_empty status["ingested"]
  end

  # A3: use the normal CLI across real polls, and confirm it stays alive after ingest.
  def test_nonempty_continuous_cli_ingests_and_keeps_polling
    payload = package
    path = download("valid", JSON.generate(payload))
    output, errors, result, timed_out = cli(limit: 2.2)
    assert timed_out, "nonempty watcher exited instead of continuing after ingestion: #{errors}"
    refute result.success?
    assert_empty errors
    assert_includes output, "Ingested chat version"
    refute File.exist?(path)
    current = status["completed"].fetch("chat")
    base = File.join(@data, "versions", "chat", current["version"])
    assert_equal payload["raw_json"], File.binread(File.join(base, "raw.json"))
    assert_equal payload["markdown"], File.binread(File.join(base, "conversation.md"))
    assert_equal current, status["ingested"]["chat"]
  end

  # A3: --once keeps exactly two scans and the short sleep for either queue size.
  def test_once_always_scans_twice_and_sleeps_for_stabilization
    [[], ["chat"]].each do |ids|
      write_queue(ids)
      instance = watcher(once: true)
      calls, sleeps = 0, []
      instance.stub(:scan_once, -> { calls += 1 }) do
        instance.stub(:sleep, ->(duration) { sleeps << duration }) { capture_io { instance.run } }
      end
      assert_equal 2, calls
      assert_equal [0.05], sleeps
    end
  end

  # Actual --once invocations retain invalid/out-of-queue files for either queue,
  # and ingest a valid authorized capture only for the nonempty queue.
  def test_once_cli_preserves_rejections_and_authorized_ingestion
    [[], ["chat"]].each do |ids|
      write_queue(ids)
      malformed = download("invalid", "{invalid JSON")
      outside = download("outside", JSON.generate(package("outside")))
      valid = download("valid", JSON.generate(package)) unless ids.empty?
      output, errors, result, timed_out = cli(once: true)
      refute timed_out
      assert result.success?, errors
      assert_includes errors, malformed
      assert_includes errors, outside
      assert File.file?(malformed)
      assert File.file?(outside)
      if ids.empty?
        assert_empty status["ingested"]
        assert_empty files(@data)
      else
        refute File.exist?(valid)
        assert_includes output, "Ingested chat version"
        assert_equal ["chat"], status["completed"].keys
      end
    end
  end

  # B1: distinct unchanged JSON and authorization rejects each warn once in six
  # polls, remain byte-identical, and may warn again after a fresh watcher starts.
  def test_unchanged_rejects_warn_once_per_file_and_restart
    malformed = download("invalid", "{invalid JSON")
    outside = download("outside", JSON.generate(package("outside")))
    original = files(@downloads)
    instance = watcher
    output, errors = scans(instance)
    assert_empty output
    [malformed, outside].each { |path| assert_equal 1, errors.lines.count { |line| line.include?(path) } }
    assert_includes errors, "capture not in queue"
    assert_equal original, files(@downloads)
    assert_empty files(@data)
    assert_empty status["completed"]
    assert_empty status["ingested"]
    _, restarted_errors = scans(watcher)
    [malformed, outside].each { |path| assert_equal 1, restarted_errors.lines.count { |line| line.include?(path) } }
  end

  # B2: same-size edits must wait for stabilization and invalidate suppression,
  # even with the original mtime restored; ctime normally exposes the edit.
  def test_same_size_edits_reject_again_then_ingest_after_full_validation
    text = JSON.generate(package)
    invalid = text.sub('"g-p-test"', '"g-p-nope"')
    assert_equal text.bytesize, invalid.bytesize
    path = download("edited", invalid)
    instance = watcher
    _, errors = scans(instance)
    assert_equal 1, errors.lines.count { |line| line.include?(path) }
    original = File.stat(path)
    changed = invalid.sub('"g-p-nope"', '"g-p-else"')
    File.binwrite(path, changed)
    File.utime(original.atime, original.mtime, path)
    assert_empty scans(instance, 1).last
    _, errors = scans(instance)
    assert_equal 1, errors.lines.count { |line| line.include?(path) }
    assert_equal changed, File.binread(path)
    File.binwrite(path, text)
    File.utime(original.atime, original.mtime, path)
    assert_empty scans(instance, 1).first
    assert File.file?(path), "changed valid file must stabilize first"
    output, errors = scans(instance)
    assert_empty errors
    assert_equal 1, output.lines.count { |line| line.include?("Ingested chat version") }
    refute File.exist?(path)
    assert_equal ["chat"], status["completed"].keys
  end

  # B2: a same-size replacement preserving mtime still has a new inode/ctime.
  # Disappearance prunes both caches, so a recreated path can be diagnosed again.
  def test_replacement_and_disappearance_invalidate_rejection_state
    text = JSON.generate(package).sub('"g-p-test"', '"g-p-nope"')
    path = download("replaced", text)
    instance = watcher
    scans(instance)
    prior = File.stat(path)
    replacement = File.join(@downloads, "replacement.tmp")
    File.binwrite(replacement, text)
    File.utime(prior.atime, prior.mtime, replacement)
    File.rename(replacement, path)
    assert_equal prior.size, File.size(path)
    assert_equal prior.mtime, File.mtime(path)
    refute_equal prior.ino, File.stat(path).ino
    assert_empty scans(instance, 1).last
    _, errors = scans(instance)
    assert_equal 1, errors.lines.count { |line| line.include?(path) }
    File.delete(path)
    scans(instance, 1)
    assert_empty instance.instance_variable_get(:@stable)
    assert_empty instance.instance_variable_get(:@rejected)
    download("replaced", text)
    _, errors = scans(instance)
    assert_equal 1, errors.lines.count { |line| line.include?(path) }
  end

  # B3: all normal authorization/payload guards still reject before and after
  # suppression, with independent diagnostics and no archive/completion mutation.
  def test_authorization_negatives_remain_rejected_after_file_changes
    mutations = {
      "project" => ->(payload) { payload["project_id"] = "g-p-other" },
      "schema" => ->(payload) { payload["schema"] = "other" },
      "outside" => ->(payload) { payload["conversation_id"] = "outside" },
      "raw_id" => ->(payload) {
        raw = JSON.parse(payload["raw_json"]); raw["id"] = "outside"
        payload["raw_json"] = JSON.generate(raw)
        payload["raw_sha256"] = Digest::SHA256.hexdigest(payload["raw_json"])
      },
      "raw" => ->(payload) { payload["raw_json"] = {} },
      "markdown" => ->(payload) { payload["markdown"] = "" },
      "count" => ->(payload) { payload["message_count"] = 0 }
    }
    paths = mutations.map do |name, mutate|
      payload = package
      mutate.call(payload)
      download(name, JSON.generate(payload))
    end
    instance = watcher
    original = files(@downloads)
    _, errors = scans(instance)
    paths.each { |path| assert_equal 1, errors.lines.count { |line| line.include?(path) }, path }
    assert_equal original, files(@downloads)
    paths.each { |path| File.open(path, "ab") { |file| file.write("\n") } }
    changed = files(@downloads)
    _, errors = scans(instance)
    paths.each { |path| assert_equal 1, errors.lines.count { |line| line.include?(path) }, path }
    assert_equal changed, files(@downloads)
    assert_empty files(@data)
    assert_empty status["completed"]
    assert_empty status["ingested"]
  end

  # Differing staged raw/Markdown destinations remain untouched on every retry;
  # the ECT-02 archive's write ordering/transaction contract is left unchanged.
  def test_conflicting_raw_and_markdown_destinations_are_never_overwritten
    instance = watcher
    paths = %w[raw.json conversation.md].map do |name|
      text = JSON.generate(package.merge("fixture" => name))
      package_hash = Digest::SHA256.hexdigest(text)
      destination = File.join(@data, "versions", ".incoming", package_hash, name)
      FileUtils.mkdir_p(File.dirname(destination))
      File.binwrite(destination, "preserve conflicting #{name}")
      download(name, text)
    end
    original_archive, original_downloads = files(@data), files(@downloads)
    _, errors = scans(instance)
    assert_includes errors, "refusing different existing bytes"
    paths.each { |path| assert_equal 1, errors.lines.count { |line| line.include?(path) } }
    paths.each { |path| File.utime(Time.now, Time.now, path) }
    _, errors = scans(instance)
    paths.each { |path| assert_equal 1, errors.lines.count { |line| line.include?(path) } }
    assert_equal original_archive, files(@data)
    assert_equal original_downloads, files(@downloads)
    assert_empty status["completed"]
  end

  # Suppression is diagnostic-only: retries still run validation, and a new error
  # remains visible even without file changes. Unexpected exceptions still escape.
  def test_handled_error_changes_are_visible_and_unexpected_errors_propagate
    path = download("valid", JSON.generate(package))
    instance = watcher
    instance.stub(:process_capture!, ->(*) { raise CaptureWatchError, "first failure" }) do
      _, errors = scans(instance)
      assert_equal 1, errors.lines.count { |line| line.include?(path) }
    end
    instance.stub(:process_capture!, ->(*) { raise CaptureWatchError, "second failure" }) do
      _, errors = scans(instance)
      assert_includes errors, "second failure"
      assert_equal 1, errors.lines.count { |line| line.include?(path) }
    end
    instance.stub(:process_capture!, ->(*) { raise "unexpected failure" }) do
      assert_raises(RuntimeError) { scans(instance, 2) }
    end
    output, errors = scans(instance)
    assert_empty errors
    assert_includes output, "Ingested chat version"
    refute File.exist?(path)
  end
end
