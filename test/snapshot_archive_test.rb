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
    # Resolve macOS temporary-directory aliases before strict symlink validation.
    @root = File.realpath(Dir.mktmpdir("snapshot-test-"))
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

  # Install a historical v1 receipt over a valid synthetic bundle. Inputs have
  # valid past timestamps; return its original package bytes for replay tests.
  # Only this disposable fixture's receipt/index are rewritten; errors propagate.
  def legacy_capture(queue, content)
    text = JSON.generate(package(queue, content))
    current = @archive.ingest(text, queue)
    exact = current.dig("listing", "update_time") == current.dig("fetched_update", "value")
    legacy = SnapshotArchive.seal(current.merge("schema" => "chat-observation/v1",
      "freshness" => exact ? "verified-as-listed" : "unresolved"))
    base = File.join(@data, "versions", content.fetch("id"))
    [File.join(base, "observations", current.fetch("package_sha256") + ".json"),
      File.join(base, "current.json")].each { |path| File.binwrite(path, JSON.pretty_generate(legacy) + "\n") }
    text
  end

  # Enable semantic reuse only in this test's isolated tooling state directory.
  # Returns an archive instance; archive/path errors propagate.
  def cached_archive
    SnapshotArchive.new(root: @data, project_id: "g-p-test", account_id: "account-test",
      validation_cache_path: File.join(@state, "snapshot_validation_cache.json"))
  end

  # Install one valid capture and prime the cache; return queue and cached reader.
  # Uses real ingestion/selection and propagates failures.
  def prime_validation_cache
    queue, = reconcile
    @archive.ingest(JSON.generate(package(queue)), queue)
    reader = cached_archive
    reader.select(inventory.fetch("conversations"), [])
    [queue, reader]
  end

  # Count actual full raw semantic validations during a caller operation.
  # Returns [result, count]; validation exceptions propagate.
  def count_raw_validation
    count = 0
    trace = TracePoint.new(:call) do |event|
      count += 1 if event.defined_class == SnapshotArchive && event.method_id == :raw_semantics!
    end
    result = trace.enable { yield }
    [result, count]
  end

  # Replace equal-length fixture bytes and restore timestamps, even on failure.
  # Yields mutated bytes; all filesystem/caller errors propagate after restoration.
  def with_same_length_corruption(path)
    original = File.binread(path)
    stat = File.stat(path)
    changed = original.sub("Hello", "Jello")
    raise "fixture missing corruption marker" if changed == original
    File.binwrite(path, changed)
    File.utime(stat.atime, stat.mtime, path)
    yield changed
  ensure
    if original && stat
      File.binwrite(path, original)
      File.utime(stat.atime, stat.mtime, path)
    end
  end

  # Fresh operations hash every raw/Markdown and reread all historical evidence,
  # while successful unchanged content does no full raw semantic work.
  def test_cache_warm_reads_and_hashes_authoritative_files
    _, reader = prime_validation_cache
    original_read = File.method(:binread)
    original_hash = Digest::SHA256.method(:hexdigest)
    reads, hashes = [], []
    result = count = nil
    File.stub(:binread, ->(path, *args) { reads << path; original_read.call(path, *args) }) do
      Digest::SHA256.stub(:hexdigest, ->(text) { hashes << text; original_hash.call(text) }) do
        result, count = count_raw_validation { reader.select(inventory.fetch("conversations"), []) }
      end
    end
    assert_equal 0, count
    assert_equal "verified-unchanged", result.last.first.fetch("state")
    Dir.glob(File.join(@data, "versions", "**", "*")).select { |path| File.file?(path) }.each do |path|
      assert_includes reads, path
      assert_includes hashes, File.binread(path) if %w[raw.json conversation.md].include?(File.basename(path))
    end
    assert_equal @archive.version!("old-chat", result.last.first.dig("current", "version")),
      reader.version!("old-chat", result.last.first.dig("current", "version"))
  end

  # Same-length restored-mtime corruption must fail for current, noncurrent and
  # unreferenced bundles. Cache entries cannot authorize either payload's bytes.
  def test_cache_corruption_across_history_and_unreferenced_bundles
    queue, reader = prime_validation_cache
    %w[Hello2 Hello3].each { |text| @archive.ingest(JSON.generate(package(queue, raw(text: text))), queue) }
    receipts = @archive.observations("old-chat")
    orphan = receipts.shift
    File.delete(File.join(@data, "versions/old-chat/observations", orphan.fetch("package_sha256") + ".json"))
    File.binwrite(File.join(@data, "versions/old-chat/current.json"), JSON.generate(receipts.last))
    reader.select(inventory.fetch("conversations"), [])
    versions.each do |metadata_path|
      %w[raw.json conversation.md].each do |member|
        path = File.join(File.dirname(metadata_path), member)
        with_same_length_corruption(path) { assert_raises(SnapshotArchiveError) { reader.select(inventory.fetch("conversations"), []) } }
      end
    end
  end

  # A deliberate raw-hash bypass makes the corruption safety assertion fail,
  # demonstrating that the control detects omission of mandatory byte hashing.
  def test_cache_safety_control_detects_a_hash_bypass
    _, reader = prime_validation_cache
    path = Dir.glob(File.join(@data, "versions/old-chat/*/raw.json")).fetch(0)
    original_hash = Digest::SHA256.method(:hexdigest)
    expected = original_hash.call(File.binread(path))
    with_same_length_corruption(path) do |changed|
      Digest::SHA256.stub(:hexdigest, ->(text) { text == changed ? expected : original_hash.call(text) }) do
        assert_raises(Minitest::Assertion) do
          assert_raises(SnapshotArchiveError) { reader.select(inventory.fetch("conversations"), []) }
        end
      end
    end
  end

  # Changed raw hashes force real strict parsing, binding and whole-graph checks,
  # including inactive branches, even when metadata's exact hash is recomputed.
  def test_cache_misses_revalidate_raw_semantics_and_identity
    _, reader = prime_validation_cache
    path = Dir.glob(File.join(@data, "versions/old-chat/*/raw.json")).fetch(0)
    metadata_path = File.join(File.dirname(path), "version.json")
    original, metadata_text = File.binread(path), File.binread(metadata_path)
    mutations = [
      ->(content) { content["id"] = "another-chat" },
      ->(content) { content["account_id"] = "other-account" },
      ->(content) { content["project_id"] = "other-project" },
      ->(content) { content["conversation_id"] = "another-chat" },
      ->(content) { content["mapping"]["inactive"]["parent"] = "absent" },
      ->(content) { content["mapping"]["inactive"]["parent"] = "inactive" },
      ->(content) { content["mapping"]["inactive"]["message"] = {} },
      ->(content) { content["unsafe_number"] = 9_007_199_254_740_992 }
    ].map do |mutation|
      content = JSON.parse(original)
      mutation.call(content)
      JSON.generate(content)
    end
    mutations += [original.sub('{', '{"id":"duplicate",'), original.sub('"preserve":true', '"preserve":1e999')]
    mutations.each do |changed|
      File.binwrite(path, changed)
      metadata = JSON.parse(metadata_text).merge("raw_sha256" => Digest::SHA256.hexdigest(changed))
      File.binwrite(metadata_path, JSON.generate(SnapshotArchive.seal(metadata)))
      called = false
      original_validation = reader.method(:raw_semantics!)
      reader.stub(:raw_semantics!, ->(*args) { called = true; original_validation.call(*args) }) do
        assert_raises(SnapshotArchiveError, JSON::ParserError) { reader.select(inventory.fetch("conversations"), []) }
      end
      assert called, "cache miss bypassed full validation"
    end
  ensure
    File.binwrite(path, original) if original
    File.binwrite(metadata_path, metadata_text) if metadata_text
  end

  # A damaged or foreign cache is disposable; valid policy changes invalidate
  # entries. No fallback can turn invalid authoritative raw into success.
  def test_cache_lifecycle_misses_and_policy_invalidation
    _, reader = prime_validation_cache
    path = File.join(@state, "snapshot_validation_cache.json")
    original = File.binread(path)
    expected = reader.select(inventory.fetch("conversations"), [])
    envelope = JSON.parse(original)
    wrong_checksum = JSON.generate(envelope.merge("sha256" => "0" * 64))
    variants = [nil, "", "{", "[]", wrong_checksum]
    policy_changed = nil
    %w[binding policy entries].each do |field|
      changed = JSON.parse(original)
      changed["payload"][field] = case field
      when "binding" then @archive.binding.merge("account_id" => "foreign-account")
      when "policy" then "0" * 64
      else { "0" * 64 => { "value" => "invented", "status" => "valid" } }
      end
      changed["sha256"] = Digest::SHA256.hexdigest(JSON.generate(changed["payload"]))
      text = JSON.generate(changed)
      policy_changed = text if field == "policy"
      variants << text
    end
    variants.each do |text|
      text ? File.binwrite(path, text) : File.delete(path)
      result = count = nil
      capture_io { result, count = count_raw_validation { reader.select(inventory.fetch("conversations"), []) } }
      assert_equal expected, result
      assert_equal 1, count
      assert_equal text, File.binread(path) if text && text != policy_changed
    end
    File.binwrite(path, original)
    raw_path = Dir.glob(File.join(@data, "versions/old-chat/*/raw.json")).fetch(0)
    with_same_length_corruption(raw_path) do
      File.delete(path)
      assert_raises(SnapshotArchiveError) { reader.select(inventory.fetch("conversations"), []) }
      refute File.exist?(path), "failed validation published a success cache"
    end
  end

  # Unavailable writes, symlink/directory/hardlink/foreign destinations and
  # interrupted atomic publication preserve authoritative decisions and files.
  def test_cache_unavailable_unsafe_and_interrupted_publication
    _, reader = prime_validation_cache
    path = File.join(@state, "snapshot_validation_cache.json")
    original = File.binread(path)
    expected = reader.select(inventory.fetch("conversations"), [])
    destination = File.join(@root, "foreign")
    File.binwrite(destination, "foreign bytes")
    File.delete(path)
    [-> { File.symlink(destination, path) }, -> { Dir.mkdir(path) }, -> { File.link(destination, path) },
      -> { File.binwrite(path, "foreign bytes") }].each do |install|
      install.call
      result = nil
      capture_io { result = reader.select(inventory.fetch("conversations"), []) }
      assert_equal expected, result
      assert_equal "foreign bytes", File.binread(destination)
      File.directory?(path) ? Dir.rmdir(path) : File.delete(path)
    end
    File.binwrite(path, original)
    rename = File.method(:rename)
    File.stub(:rename, ->(source, target) { target == path ? (raise Errno::EACCES, "synthetic interrupted cache publication") : rename.call(source, target) }) do
      capture_io { assert_equal expected, reader.select(inventory.fetch("conversations"), []) }
    end
    assert_equal original, File.binread(path)
    assert_empty Dir.glob(path + ".tmp-*")
    open_file = File.method(:open)
    File.stub(:open, ->(target, *args, &block) { target.start_with?(path) ? (raise Errno::EACCES, "synthetic unavailable cache") : open_file.call(target, *args, &block) }) do
      capture_io { assert_equal expected, reader.select(inventory.fetch("conversations"), []) }
    end
    assert_raises(SnapshotArchiveError) do
      SnapshotArchive.new(root: @data, project_id: "g-p-test", account_id: "account-test", validation_cache_path: File.join(@data, "cache"))
    end
  end

  # Every new operation notices index/journal/namespace changes. Compare cached
  # selection directly with uncached verification, including valid repair rules.
  def test_cache_live_namespace_journal_and_index_checks
    _, reader = prime_validation_cache
    base = File.join(@data, "versions/old-chat")
    index = File.join(base, "current.json")
    original_index = File.binread(index)
    File.delete(index)
    assert_nil reader.current!("old-chat")
    assert_equal @archive.select(inventory.fetch("conversations"), []), reader.select(inventory.fetch("conversations"), [])
    assert_equal JSON.parse(original_index), reader.current!("old-chat", repair: true)
    version_dir = File.dirname(Dir.glob(File.join(base, "*/raw.json")).fetch(0))
    member = File.join(version_dir, "conversation.md")
    text = File.binread(member)
    File.delete(member)
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.binwrite(member, text)
    extra = File.join(version_dir, "unexpected")
    File.binwrite(extra, "unexpected")
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.delete(extra)
    File.rename(member, member + ".saved")
    File.symlink(member + ".saved", member)
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.delete(member)
    File.rename(member + ".saved", member)
    receipt_path = Dir.glob(File.join(base, "observations/*.json")).fetch(0)
    receipt = File.binread(receipt_path)
    changed = JSON.parse(receipt)
    changed["source"]["generated_at"] = "2026-10-13T12:00:00.000Z"
    File.binwrite(receipt_path, JSON.generate(SnapshotArchive.seal(changed)))
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.binwrite(receipt_path, receipt)
    File.rename(receipt_path, receipt_path + ".saved")
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.delete(index)
    assert_nil reader.current!("old-chat", repair: true)
    File.rename(receipt_path + ".saved", receipt_path)
    reader.current!("old-chat", repair: true)
    File.binwrite(index, JSON.generate(SnapshotArchive.seal(JSON.parse(receipt).merge("package_sha256" => "0" * 64))))
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat", repair: true) }
  end

  # Reusing an archive instance never reuses selection or completion state after
  # ingestion, a listing change, or changed archive binding. Raw reuse is separate.
  def test_cache_same_instance_incremental_ingestion_and_listing_changes
    queue, reader = prime_validation_cache
    changed_listing = inventory.fetch("conversations").map { |entry| entry.merge("update_time" => "2026-10-08T12:00:00.000Z") }
    result, count = count_raw_validation { reader.select(changed_listing, []) }
    assert_equal "updated", result.last.first.fetch("state")
    assert_equal 0, count
    reader.ingest(JSON.generate(package(queue, raw(text: "New version"))), queue)
    result, count = count_raw_validation { reader.select(inventory.fetch("conversations"), []) }
    assert_equal @archive.current!("old-chat"), result.last.first.fetch("current")
    assert_equal 0, count
    binding_path = File.join(@data, "versions/binding.json")
    File.binwrite(binding_path, JSON.generate(SnapshotArchive.seal(@archive.binding.merge("account_id" => "other-account"))))
    assert_raises(SnapshotArchiveError) { reader.select(inventory.fetch("conversations"), []) }
  end

  # Source-byte policy changes miss, while a relocated archive with identical
  # bytes/bindings can reuse successes. Changed content still requires validation.
  def test_cache_source_fingerprint_and_relocated_archive
    queue, reader = prime_validation_cache
    cache_path = File.join(@state, "snapshot_validation_cache.json")
    original_cache = File.binread(cache_path)
    original_read = File.method(:binread)
    source_path = File.expand_path("../snapshot_archive.rb", __dir__)
    result = count = nil
    File.stub(:binread, ->(path, *args) { original_read.call(path, *args) + (path == source_path ? "\n# changed verifier policy\n" : "") }) do
      result, count = count_raw_validation { reader.select(inventory.fetch("conversations"), []) }
    end
    assert_equal 1, count
    File.binwrite(cache_path, original_cache)
    copy = File.join(@root, "archive-copy")
    FileUtils.cp_r(@data, copy)
    relocated = SnapshotArchive.new(root: copy, project_id: "g-p-test", account_id: "account-test", validation_cache_path: cache_path)
    copied_result, count = count_raw_validation { relocated.select(inventory.fetch("conversations"), []) }
    assert_equal result, copied_result
    assert_equal 0, count
    _, count = count_raw_validation { relocated.ingest(JSON.generate(package(queue, raw(text: "New bytes"))), queue) }
    assert_operator count, :>=, 1
    _, count = count_raw_validation { reader.select(inventory.fetch("conversations"), []) }
    assert_equal 0, count
  end

  # Warm readers notice added/renamed receipts and bundles, bad metadata,
  # stale indexes and missing bindings; repairs preserve the original journal.
  def test_cache_namespace_additions_metadata_tampering_and_stale_indexes
    queue, reader = prime_validation_cache
    base = File.join(@data, "versions/old-chat")
    index = File.join(base, "current.json")
    old_index = File.binread(index)
    @archive.ingest(JSON.generate(package(queue, raw(text: "Hello later"), started: "2026-10-13T12:00:00.000Z")), queue)
    latest = reader.current!("old-chat")
    File.binwrite(index, old_index)
    assert_nil reader.current!("old-chat")
    assert_equal latest, reader.current!("old-chat", repair: true)
    metadata = Dir.glob(File.join(base, "*/version.json")).fetch(0)
    original = File.binread(metadata)
    File.binwrite(metadata, JSON.generate(JSON.parse(original).merge("markdown_sha256" => "0" * 64)))
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.binwrite(metadata, original)
    receipt_path = Dir.glob(File.join(base, "observations/*.json")).fetch(0)
    addition = File.join(base, "observations", "0" * 64 + ".json")
    FileUtils.cp(receipt_path, addition)
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.delete(addition)
    bundle = File.dirname(metadata)
    renamed = File.join(base, "0" * 64)
    File.rename(bundle, renamed)
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    File.rename(renamed, bundle)
    FileUtils.mkdir_p(renamed)
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
    Dir.rmdir(renamed)
    File.rename(bundle, bundle + ".saved")
    assert_raises(Errno::ENOENT) { reader.current!("old-chat") }
    File.rename(bundle + ".saved", bundle)
    File.delete(File.join(@data, "versions/binding.json"))
    assert_raises(SnapshotArchiveError) { reader.current!("old-chat") }
  end

  # Invoke the actual CLI in a fresh process with an isolated tooling/.state.
  # Freeze only report generation time so complete queue checksums can be compared;
  # return report, validated queue and completed IDs, raising on CLI failures.
  def cache_cli(tooling, full_verify: false, date: nil)
    clock = File.join(tooling, "fixed_clock.rb")
    File.binwrite(clock, 'class << Time; def now; Time.utc(2026, 10, 30); end; end')
    output, errors, status = Open3.capture3({ "CHAT_EXPORT_FULL_VERIFY" => full_verify ? "1" : nil,
      "CHAT_EXPORT_ONLY_LOCAL_DATE" => date }, RbConfig.ruby, "-r", clock,
      File.join(tooling, "reconcile_exports.rb"), @data, File.join(@data, "Synthetic Project Inventory.json"))
    assert status.success?, errors
    assert_includes output, "Pending IDs:"
    assert_empty errors
    state = File.join(tooling, ".state")
    values = %w[reconciliation pending_ids completed_ids].map { |name| read_json(File.join(state, name + ".json")) }
    SnapshotArchive.queue!(values[1])
    values
  end

  # New-process full/cold/warm CLI decisions agree through actual browser fixture
  # and watcher ingestion, recovery limiting, completion and date-scoped selection.
  def test_cache_cli_equivalence_and_browser_watcher_journey
    tooling = File.join(@root, "tooling")
    FileUtils.mkdir_p(tooling)
    Dir.glob(File.expand_path("../*.{rb,js}", __dir__)).each { |source| FileUtils.cp(source, tooling) }
    rows = [row] + (1..12).map { |number| row("legacy-#{number}", update: "2026-10-08T12:00:00.000Z") }
    FileUtils.mkdir_p(File.join(@data, "raw"))
    rows.drop(1).each { |entry| File.binwrite(File.join(@data, "raw", entry["id"] + ".json"), JSON.generate("id" => entry["id"])) }
    reconcile(inventory(rows))
    reference = cache_cli(tooling, full_verify: true)
    cold = cache_cli(tooling)
    assert_equal reference, cold
    assert_equal reference, cache_cli(tooling)
    queue = cold[1]
    assert_equal 10, queue.fetch("pending").count { |entry| entry["reason"] == "unknown-legacy" }
    File.binwrite(File.join(@state, "pending_ids.json"), JSON.generate(queue))
    downloaded = browser(queue, [raw], { "stopAfter" => 1 })
    watch(downloaded.fetch("downloads").first.fetch("text"))
    reference = cache_cli(tooling, full_verify: true)
    assert_equal reference, cache_cli(tooling)
    assert_equal reference, cache_cli(tooling)
    assert_equal "verified-unchanged", reference[0].fetch("freshness").find { |entry| entry["id"] == "old-chat" }.fetch("state")
    assert_equal cache_cli(tooling, full_verify: true, date: "2026-10-09"), cache_cli(tooling, date: "2026-10-09")
    path = Dir.glob(File.join(@data, "versions/old-chat/*/raw.json")).fetch(0)
    with_same_length_corruption(path) do
      _, errors, status = Open3.capture3(RbConfig.ruby, File.join(tooling, "reconcile_exports.rb"), @data)
      refute status.success?
      assert_includes errors, "RECONCILIATION FAILED"
    end
  end

  # The inclusive tolerance crosses second boundaries without accepting >1 hour,
  # missing/invalid evidence, or either source timestamp after request start.
  def test_one_hour_freshness_boundaries_and_clock_guards
    listing = inventory.fetch("conversations").first
    [-3_600_001, -3_600_000, -3_599_999, -155, 0, 155, 60_000, 3_599_999, 3_600_000, 3_600_001].each do |offset|
      fetched = { status: "valid", value: (Time.iso8601(UPDATE) + Rational(offset, 1000)).iso8601(3) }
      expected = offset.abs <= 3_600_000 ? "verified-as-listed" : "unresolved"
      assert_equal expected, @archive.freshness(listing, fetched, CAPTURE), offset.inspect
    end
    crossing = listing.merge("update_time" => "2026-10-09T11:59:59.999Z")
    fetched = { status: "valid", value: "2026-10-09T12:00:00.001Z" }
    assert_equal "verified-as-listed", @archive.freshness(crossing, fetched, CAPTURE)
    %w[missing invalid].each do |status|
      assert_equal "unresolved", @archive.freshness(listing, { status: status, value: nil }, CAPTURE)
      assert_equal "unresolved", @archive.freshness(listing.merge("update_time_status" => status, "update_time" => nil), fetched, CAPTURE)
    end
    fetched = { status: "valid", value: CAPTURE }
    future = "2026-10-12T12:00:00.500Z"
    assert_equal "unresolved", @archive.freshness(listing.merge("update_time" => future), fetched, CAPTURE)
    assert_equal "unresolved", @archive.freshness(listing.merge("update_time" => CAPTURE), fetched.merge(value: future), CAPTURE)
    assert_equal "unresolved", @archive.freshness(listing.merge("update_time" => CAPTURE, "last_observed_at" => future), fetched, CAPTURE)
  end

  # Exercise the real browser program, watcher, checkpoint and reconciliation for
  # a 155 ms discrepancy. A subsequent 1 ms listing change must still queue work.
  def test_tolerant_pipeline_keeps_listing_change_detection_exact
    listed = "2026-10-09T12:00:32.599Z"
    rows = [row(update: listed)]
    queue, = reconcile(inventory(rows))
    content = raw(update: Time.iso8601("2026-10-09T12:00:32.754Z").to_f)
    downloaded = browser(queue, [content])
    assert_nil downloaded["error"]
    refute File.exist?(watch(downloaded["downloads"].fetch(0).fetch("text")))
    current = @archive.current!("old-chat")
    assert_equal "chat-observation/v3", current["schema"]
    assert_equal "verified-as-listed", current["freshness"]
    assert read_json(File.join(@state, "capture_status.json"))["completed"].key?("old-chat")
    repeated, report = reconcile(inventory(rows))
    assert_empty repeated["pending"]
    assert_equal 1, report["completed_conversation_count"]
    changed, = reconcile(inventory([row(update: "2026-10-09T12:00:32.600Z")]))
    assert_equal ["old-chat"], changed["pending"].map { |entry| entry["id"] }
  end

  # Reassess checked v1 evidence locally, preserve its bytes and exact-rule truth,
  # and allow replay of the original package after the policy update.
  def test_legacy_receipt_reassessment_and_replay_preserve_history
    queue, = reconcile
    text = legacy_capture(queue, raw(update: "2026-10-09T12:00:00.155Z"))
    NamedExports.new(@archive).write!("old-chat")
    legacy = @archive.current!("old-chat")
    receipt_path = File.join(@data, "versions", "old-chat", "observations", legacy["package_sha256"] + ".json")
    original_receipt = File.binread(receipt_path)
    File.binwrite(receipt_path, JSON.pretty_generate(SnapshotArchive.seal(legacy.merge("freshness" => "verified-as-listed"))))
    assert_raises(SnapshotArchiveError) { @archive.current!("old-chat") }
    File.binwrite(receipt_path, original_receipt)
    original = files
    repeated, report = reconcile
    assert_empty repeated["pending"]
    assert_equal 1, report["completed_conversation_count"]
    assert_equal 0, report["archived_unresolved_count"]
    assert_equal "verified-as-listed", report["freshness"].first["freshness"]
    assert_equal "unresolved", @archive.current!("old-chat")["freshness"]
    assert_equal original, files
    File.binwrite(File.join(@state, "pending_ids.json"), JSON.pretty_generate(queue))
    refute File.exist?(watch(text))
    assert read_json(File.join(@state, "capture_status.json"))["completed"].key?("old-chat")
    assert_equal "chat-observation/v1", @archive.current!("old-chat")["schema"]
    assert_equal original, files
    mixed = JSON.generate(package(queue, raw(text: "New content", update: "2026-10-09T12:00:00.155Z"),
      started: "2026-10-13T12:00:00.000Z"))
    watch(mixed)
    assert_equal %w[chat-observation/v1 chat-observation/v3], @archive.observations("old-chat").map { |receipt| receipt["schema"] }
    assert_equal original_receipt, File.binread(receipt_path)
  end

  # A legacy mismatch outside tolerance remains unresolved. Re-sealing a forged
  # v1 freshness claim or an unknown observation schema cannot bypass validation.
  def test_legacy_strict_validation_and_unknown_policy_fail_closed
    queue, = reconcile
    legacy_capture(queue, raw(update: "2026-10-09T13:00:00.001Z"))
    pending, report = reconcile
    assert_empty pending["pending"]
    assert_equal 1, report["completed_conversation_count"]
    assert_equal 1, report["archived_unresolved_count"]
    current = @archive.current!("old-chat")
    path = File.join(@data, "versions", "old-chat", "observations", current["package_sha256"] + ".json")
    [current.merge("freshness" => "verified-as-listed"), current.merge("schema" => "chat-observation/v99")].each do |forged|
      File.binwrite(path, JSON.pretty_generate(SnapshotArchive.seal(forged)))
      assert_raises(SnapshotArchiveError) { @archive.current!("old-chat") }
    end
  end

  # A >hour mismatch completes one exact listing, leaving all recovery slots for
  # uncaptured history. Changed title/update fields still trigger inspection.
  def test_completed_mismatch_advances_legacy_backlog_and_reports_diagnostics
    queue, = reconcile
    original = package(queue, raw(update: "2026-08-16T01:05:46.327Z"))
    text = JSON.generate(original)
    watch(text)
    before = files
    legacy = 12.times.map { |index| row("legacy-#{index}") }
    legacy.each { |entry| File.binwrite(File.join(@data, "2020-01-01 - #{entry['title']}.md"), "Legacy #{entry['id']}") }
    queue, report = reconcile(inventory([row] + legacy))
    assert_equal 10, queue["pending"].length
    refute_includes queue["pending"].map { |entry| entry["id"] }, "old-chat"
    assert_equal 1, report["completed_conversation_count"]
    assert_equal 0, report["freshness_verified_count"]
    assert_equal 1, report["archived_unresolved_count"]
    before.reject { |path, _| path.end_with?("Project Inventory.json") }.each { |path, hash| assert_equal hash, files[path] }
    queue["pending"].each { |entry| @archive.ingest(JSON.generate(package(queue, raw(entry["id"]))), queue) }
    remaining, report = reconcile(inventory([row] + legacy))
    assert_equal 2, remaining["pending"].length
    assert_equal 11, report["completed_conversation_count"]
    changed = row.merge("title" => "Renamed")
    assert_equal ["old-chat"], reconcile(inventory([changed])).first["pending"].map { |entry| entry["id"] }
  end

  # Existing v2 receipts validate under their original one-second policy, while
  # today's diagnostic uses one hour. Replays preserve every historical byte.
  def test_v2_receipt_policy_is_preserved_and_reassessed_without_recapture
    queue, = reconcile
    text = JSON.generate(package(queue, raw(update: "2026-10-09T12:00:05.000Z")))
    current = @archive.ingest(text, queue)
    old = SnapshotArchive.seal(current.merge("schema" => "chat-observation/v2", "freshness" => "unresolved"))
    base = File.join(@data, "versions", "old-chat")
    [File.join(base, "current.json"), File.join(base, "observations", old["package_sha256"] + ".json")].each do |path|
      File.binwrite(path, JSON.pretty_generate(old) + "\n")
    end
    before = files
    pending, report = reconcile
    assert_empty pending["pending"]
    assert_equal 1, report["freshness_verified_count"]
    assert_equal "unresolved", @archive.current!("old-chat")["freshness"]
    @archive.ingest(text, queue)
    assert_equal before, files
    forged = SnapshotArchive.seal(old.merge("freshness" => "verified-as-listed"))
    File.binwrite(File.join(base, "observations", old["package_sha256"] + ".json"), JSON.pretty_generate(forged))
    assert_raises(SnapshotArchiveError) { @archive.current!("old-chat") }
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

  # The watcher automatically produces named copies; backfill restores missing
  # copies without altering authoritative versions or overwriting legacy files.
  def test_named_exports_are_additive_and_backfillable
    File.binwrite(File.join(@data, "2020-01-01 - Legacy.md"), "Legacy unchanged\n")
    queue, = reconcile
    first = package(queue)
    watch(JSON.generate(first))
    named = Dir.glob(File.join(@data, "named", "*.md"))
    assert_equal 1, named.length
    assert_match(/2020-01-01 - Synthetic old-chat \[old-chat-[0-9a-f]{12}\]\.md\z/, named.first)
    assert_equal first["markdown"], File.binread(named.first)
    original = files
    assert_equal ["named/#{File.basename(named.first)}"], NamedExports.new(@archive).backfill!
    assert_equal original, files

    File.delete(named.first)
    output, errors, status = Open3.capture3(RbConfig.ruby,
      File.expand_path("../named_exports.rb", __dir__), @data)
    assert status.success?, errors
    assert_includes output, "Verified named Markdown exports: 1"
    assert_equal original, files

    changed = raw(text: "Updated")
    second = package(queue, changed, started: "2026-10-13T00:00:00.000Z", markdown: "Updated Markdown\n")
    watch(JSON.generate(second))
    assert_equal 2, Dir.glob(File.join(@data, "named", "*.md")).length
    assert_equal first["markdown"], File.binread(named.first)
    assert_equal "Legacy unchanged\n", File.binread(File.join(@data, "2020-01-01 - Legacy.md"))
    assert_equal 2, versions.length
  end

  # Existing unrelated same-name bytes are never overwritten, even after the
  # canonical bundle was installed; the original download remains replayable.
  def test_named_export_conflict_preserves_download_for_retry
    queue, = reconcile
    version = SnapshotArchive.digest(raw)
    name = "2020-01-01 - Synthetic old-chat [old-chat-#{version[0, 12]}].md"
    named = File.join(@data, "named", name)
    FileUtils.mkdir_p(File.dirname(named))
    File.binwrite(named, "Do not replace me")
    payload = JSON.generate(package(queue))
    assert_raises(SnapshotArchiveError) { watch(payload) }
    assert_equal "Do not replace me", File.binread(named)
    assert File.exist?(File.join(@downloads, "AFCHAT_fixture.json"))
    assert @archive.current!("old-chat")
    File.delete(named)
    watch(payload)
    assert_equal "## Message 1\n\n### User\n\nHello\n", File.binread(named)
    refute File.exist?(File.join(@downloads, "AFCHAT_fixture.json"))
  end

  # Missing creation evidence is labeled as capture date; unsafe title
  # characters cannot create paths or remove the title from the filename.
  def test_named_export_uses_safe_title_and_labeled_capture_date_fallback
    listing = row.merge("title" => nil, "create_time" => nil)
    queue, = reconcile(inventory([listing]))
    source = raw(extra: { "title" => "A/Title: with\n punctuation?", "create_time" => nil })
    watch(JSON.generate(package(queue, source)))
    named = Dir.glob(File.join(@data, "named", "*.md"))
    assert_equal 1, named.length
    assert_match(/captured-2026-10-12 - A Title with punctuation \[old-chat-[0-9a-f]{12}\]\.md\z/, named.first)
    refute_includes File.basename(named.first), "/"
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
  def test_listing_advance_capture_completion_and_future_reselection
    queue, = reconcile
    @archive.ingest(JSON.generate(package(queue)), queue)
    advanced = "2026-10-11T00:00:00.000Z"
    scan = "2026-10-11T12:00:00.000Z"
    queue, = reconcile(inventory([row(update: advanced)], scan: scan))
    2.times do |index|
      text = JSON.generate(package(queue, started: "2026-10-1#{2 + index}T12:00:00.000Z"))
      @archive.ingest(text, queue)
      @archive.ingest(text, queue) # Exact replay does not create another version.
    end
    assert_equal 1, versions.length
    assert_equal "unresolved", @archive.current!("old-chat")["freshness"]
    pending, report = reconcile(inventory([row(update: advanced)], scan: scan))
    assert_empty pending["pending"]
    assert_equal "captured-unchanged", report["freshness"].first["state"]
    assert_equal 0, report["unknown_or_unresolved_count"]
    future, = reconcile(inventory([row(update: "2026-10-13T00:00:00.000Z")], scan: "2026-10-14T00:00:00.000Z"))
    assert_equal ["old-chat"], future["pending"].map { |entry| entry["id"] }
    changed = raw(update: "2026-10-13T00:00:00.000Z", text: "Caught up")
    @archive.ingest(JSON.generate(package(future, changed, started: "2026-10-15T00:00:00.000Z")), future)
    assert_equal "verified-as-listed", @archive.current!("old-chat")["freshness"]
  end

  # Daily/full-audit provenance changes do not refetch a successfully captured
  # listing revision. Real update/title changes remain eligible for inspection.
  def test_unchanged_listing_rescans_do_not_refetch_timestamp_disagreements
    queue, = reconcile
    mismatched = raw(update: "2026-10-09T13:00:03.000Z")
    2.times do |index|
      @archive.ingest(JSON.generate(package(queue, mismatched,
        started: "2026-10-1#{2 + index}T12:00:00.000Z")), queue)
    end
    future, report = reconcile(inventory(scan: "2026-10-14T00:00:00.000Z"))
    assert_empty future["pending"]
    assert_equal "captured-unchanged", report["freshness"].first["state"]
    assert_equal 1, report["archived_conversation_count"]
    assert_equal 1, report["archived_unresolved_count"]
    assert_equal 1, report["completed_conversation_count"]
    changed, = reconcile(inventory([row(update: "2026-10-13T00:00:00.000Z")],
      scan: "2026-10-14T00:00:00.000Z"))
    assert_equal ["old-chat"], changed["pending"].map { |entry| entry["id"] }
  end

  # A current update to an unresolved capture is a first inspection of changed
  # evidence, even when ten older legacy conversations fill the recovery lane.
  def test_changed_unresolved_listing_bypasses_recovery_budget
    target = "z-active-chat"
    first, = reconcile(inventory([row(target)]))
    @archive.ingest(JSON.generate(package(first, raw(target,
      update: "2026-10-09T12:00:03.000Z"))), first)
    legacy = 10.times.map { |index| row("a-legacy-#{index}") }
    FileUtils.mkdir_p(File.join(@data, "raw"))
    legacy.each do |entry|
      File.binwrite(File.join(@data, "raw", entry["id"] + ".json"), JSON.generate({ "id" => entry["id"] }))
    end
    queue, report = reconcile(inventory(legacy + [row(target, update: "2026-10-11T00:00:00.000Z")],
      scan: "2026-10-11T12:00:00.000Z"))
    assert_includes queue["pending"].map { |entry| entry["id"] }, target
    assert_equal 11, queue["pending"].length
    assert_equal target, queue["pending"].first["id"]
    assert_equal true, report["freshness"].find { |entry| entry["id"] == target }["selected"]
    changed = raw(target, update: "2026-10-11T00:00:00.000Z", text: "New daily content")
    downloaded = browser(queue, [changed], { "limit" => 1, "now" => "2026-10-13T12:00:00.000Z" })
    assert_nil downloaded["error"]
    refute File.exist?(watch(downloaded["downloads"].fetch(0).fetch("text")))
    repeated, = reconcile(inventory(legacy + [row(target, update: "2026-10-11T00:00:00.000Z")],
      scan: "2026-10-11T12:00:00.000Z"))
    refute_includes repeated["pending"].map { |entry| entry["id"] }, target
    assert_equal "verified-as-listed", @archive.current!(target)["freshness"]
  end

  # A fetch racing ahead of listing completes capture but cannot claim freshness.
  def test_newer_fetched_timestamp_is_not_a_verified_listing
    queue, = reconcile
    changed = raw(update: "2026-10-12T12:00:01.000Z", text: "Racing update")
    watch(JSON.generate(package(queue, changed)))
    current = @archive.current!("old-chat")
    assert_equal "unresolved", current["freshness"]
    assert_equal changed["update_time"], current.dig("fetched_update", "value")
    assert read_json(File.join(@state, "capture_status.json"))["completed"].key?("old-chat")
    assert_empty reconcile.first["pending"]
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

  # Missing/invalid source times remain explicit without refetch on later audits.
  def test_unusable_source_times_do_not_refetch_daily
    [nil, "invalid"].each do |update|
      FileUtils.rm_rf(File.join(@data, "versions"))
      queue, = reconcile(inventory([row(update: update)]))
      @archive.ingest(JSON.generate(package(queue, raw(update: update))), queue)
      pending, report = reconcile(inventory([row(update: update)]))
      assert_empty pending["pending"]
      assert_equal "captured-unchanged", report["freshness"].first["state"]
      queue, = reconcile(inventory([row(update: update)], scan: "2026-10-14T00:00:00.000Z"))
      assert_empty queue["pending"]
    end
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
