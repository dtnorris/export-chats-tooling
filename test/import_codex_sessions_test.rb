# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../import_codex_sessions"

class ImportCodexSessionsTest < Minitest::Test
  ID = "12345678-1234-1234-1234-123456789abc"
  START = "2026-10-10T22:01:57.284Z"

  def test_default_source_covers_all_session_months
    assert_equal File.expand_path("~/.codex/sessions"), CodexSessionImporter::DEFAULT_SOURCE
  end

  def setup
    @dir = Dir.mktmpdir("codex-import-test-")
    @source = File.join(@dir, "source")
    @data = File.join(@dir, "data")
    FileUtils.mkdir_p([@source, @data])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def row(type, payload, timestamp = START)
    { "timestamp" => timestamp, "type" => type, "payload" => payload }
  end

  def response_message(role, text, phase = nil)
    payload = { "type" => "message", "id" => "msg-#{role}-#{text.length}", "role" => role,
                "content" => [{ "type" => role == "assistant" ? "output_text" : "input_text", "text" => text }] }
    payload["phase"] = phase if phase
    row("response_item", payload)
  end

  def fixture(id: ID, complete: true, heading: "# Synthetic test task", tool: true)
    records = [row("session_meta", { "id" => id, "session_id" => id, "timestamp" => START,
                                      "cwd" => "/tmp/synthetic-project",
                                      "git" => { "branch" => "main", "commit_hash" => "abc" } })]
    records << response_message("developer", "PRIVATE DEVELOPER INSTRUCTION")
    records << response_message("user", "#{heading}\nPerform a synthetic check.")
    records << row("event_msg", { "type" => "item_completed", "item" => {
      "type" => "UserMessage", "content" => [{ "type" => "text", "text" => heading }] } })
    records << response_message("assistant", "I will run a check.", "commentary")
    records << row("response_item", { "type" => "reasoning", "summary" => ["PRIVATE REASONING"] })
    if tool
      records << row("response_item", { "type" => "custom_tool_call", "call_id" => "call-1",
                                        "name" => "exec", "input" => '{"cmd":"ruby -v"}' })
      records << row("event_msg", { "type" => "item_completed", "item" => {
        "type" => "CommandExecution", "command" => ["ruby", "-v"],
        "status" => "completed", "exit_code" => 0, "cwd" => "/tmp/synthetic-project",
        "aggregated_output" => "ruby synthetic\n" } })
      records << row("response_item", { "type" => "custom_tool_call_output", "call_id" => "call-1",
                                        "output" => [{ "type" => "text", "text" => "ruby synthetic\n" }] })
    end
    records << response_message("assistant", "Validation passed; synthetic handoff.", "final_answer")
    records << row("event_msg", { "type" => "item_completed", "item" => {
      "type" => "AgentMessage", "content" => [{ "type" => "text", "text" => "Validation passed; synthetic handoff." }] } })
    records << row("event_msg", { "type" => "task_complete" }) if complete
    records
  end

  def write_rollout(records, folder: @source, id: ID)
    FileUtils.mkdir_p(folder)
    path = File.join(folder, "rollout-2026-10-10T18-01-57-#{id}.jsonl")
    File.binwrite(path, records.map { |record| JSON.generate(record) + "\n" }.join)
    path
  end

  def run_import(dry_run: false)
    output = StringIO.new
    errors = StringIO.new
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
                                    dry_run: dry_run, verbose: true,
                                    output: output, errors: errors).run
    [code, output.string, errors.string]
  end

  def raw_path(id = ID)
    File.join(@data, "raw", "codex", "#{id}.jsonl")
  end

  def markdown_paths
    Dir.glob(File.join(@data, "*.md"))
  end

  def test_complete_session_preserves_raw_and_order_without_duplicate_messages_or_reasoning
    path = write_rollout(fixture)
    assert_equal 0, run_import.first
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "Raw SHA-256: `#{Digest::SHA256.file(path).hexdigest}`"
    assert_includes md, "Session ID: `#{ID}`"
    assert_includes md, "Started: `2026-10-10T22:01:57.284Z`"
    assert_includes md, "Status: complete"
    assert_includes md, "Working directory: `/tmp/synthetic-project`"
    assert_operator md.index("### User"), :<, md.index("### Assistant")
    assert_operator md.index("### Tool call"), :<, md.index("### Command execution")
    assert_operator md.index("### Command execution"), :<, md.index("### Tool result")
    assert_operator md.index("### Tool result"), :<, md.index("final_answer")
    assert_equal 1, md.scan("Perform a synthetic check.").length
    assert_equal 1, md.scan("Validation passed; synthetic handoff.").length
    refute_includes md, "PRIVATE REASONING"
    refute_includes md, "PRIVATE DEVELOPER INSTRUCTION"
    assert_includes md, "ruby synthetic"
  end

  def test_recursive_discovery_and_identical_second_import_are_idempotent
    write_rollout(fixture, folder: File.join(@source, "2026", "10"))
    assert_equal 0, run_import.first
    before = [raw_path, markdown_paths.fetch(0)].to_h { |path| [path, [File.mtime(path), Digest::SHA256.file(path).hexdigest]] }
    code, out, errors = run_import
    assert_equal 0, code, errors
    assert_includes out, "unchanged=1"
    assert_equal before, before.keys.to_h { |path| [path, [File.mtime(path), Digest::SHA256.file(path).hexdigest]] }
  end

  def test_modified_same_id_is_explicit_conflict_and_preserves_existing_files
    path = write_rollout(fixture)
    assert_equal 0, run_import.first
    original = [raw_path, markdown_paths.fetch(0)].map { |name| File.binread(name) }
    File.open(path, "ab") { |file| file.write(JSON.generate(row("event_msg", { "type" => "token_count" })) + "\n") }
    code, out, errors = run_import
    assert_equal 1, code
    assert_includes errors, "same-ID raw content changed"
    assert_includes out, "failed=1"
    assert_equal original, [raw_path, markdown_paths.fetch(0)].map { |name| File.binread(name) }
  end

  def test_incomplete_session_is_labeled_and_later_growth_is_detected
    path = write_rollout(fixture(complete: false))
    assert_equal 0, run_import.first
    assert_includes File.binread(markdown_paths.fetch(0)), "incomplete (no task_complete record)"
    File.open(path, "ab") { |file| file.write(JSON.generate(row("event_msg", { "type" => "task_complete" })) + "\n") }
    assert_equal 1, run_import.first
  end

  def test_dry_run_does_not_write_or_touch_unrelated_chatgpt_archive
    write_rollout(fixture)
    FileUtils.mkdir_p(File.join(@data, "raw"))
    chat = File.join(@data, "raw", "chatgpt-id.json")
    File.binwrite(chat, "private existing archive")
    code, out, = run_import(dry_run: true)
    assert_equal 0, code
    assert_includes out, "imported=1"
    assert_equal [chat], Dir.glob(File.join(@data, "raw", "**", "*.*"))
    assert_empty markdown_paths
    assert_equal 0, run_import.first
    assert_equal "private existing archive", File.binread(chat)
  end

  def test_missing_heading_uses_deterministic_neutral_title
    write_rollout(fixture(heading: "A task without a title"))
    assert_equal 0, run_import.first
    assert_equal "2026-10-10 - Codex Session 12345678 [12345678].md", File.basename(markdown_paths.fetch(0))
  end

  def test_malformed_and_missing_identity_fail_without_archive_files
    path = write_rollout(fixture)
    File.open(path, "ab") { |file| file.write("{truncated") }
    assert_equal 1, run_import.first
    assert_empty markdown_paths
    assert_empty Dir.glob(File.join(@data, "raw", "**", "*.jsonl"))
    records = fixture
    records[0]["payload"].delete("id")
    write_rollout(records)
    assert_equal 1, run_import.first
    assert_empty markdown_paths
  end

  def test_duplicate_session_ids_are_preflight_conflicts
    write_rollout(fixture)
    write_rollout(fixture, folder: File.join(@source, "copy"))
    code, out, errors = run_import
    assert_equal 1, code
    assert_includes errors, "duplicate session ID"
    assert_includes out, "conflicting=2"
    assert_empty markdown_paths
  end

  def test_existing_markdown_collision_is_never_overwritten
    write_rollout(fixture)
    md = File.join(@data, "2026-10-10 - Synthetic test task [12345678].md")
    File.binwrite(md, "another session's archive")
    assert_equal 1, run_import.first
    assert_equal "another session's archive", File.binread(md)
    refute File.exist?(raw_path)
  end

  def test_partial_pair_is_repaired_when_existing_raw_is_identical
    path = write_rollout(fixture)
    FileUtils.mkdir_p(File.dirname(raw_path))
    FileUtils.cp(path, raw_path)
    code, out, = run_import
    assert_equal 0, code
    assert_includes out, "imported=1"
    assert_equal File.binread(path), File.binread(raw_path)
    assert_equal 1, markdown_paths.length
  end

  def test_symlinked_source_and_destination_are_rejected
    real = write_rollout(fixture)
    FileUtils.mkdir_p(File.join(@source, "linked"))
    File.symlink(real, File.join(@source, "linked", File.basename(real)))
    assert_equal 1, run_import.first
    assert_equal 1, markdown_paths.length # valid original can still import
    FileUtils.rm_rf(File.join(@data, "raw"))
    File.symlink(@source, File.join(@data, "raw"))
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "symlink in destination"
  end

  def test_unexpected_response_structure_fails_closed
    records = fixture
    records.insert(3, row("response_item", { "type" => "unknown_future_item" }))
    write_rollout(records)
    assert_equal 1, run_import.first
    assert_empty markdown_paths
  end

  def test_missing_activity_timestamp_keeps_source_order_with_record_label
    records = fixture
    records[4].delete("timestamp") # Assistant commentary after the user record.
    write_rollout(records)
    assert_equal 0, run_import.first
    md = File.binread(markdown_paths.fetch(0))
    assert_operator md.index("### User"), :<, md.index("record 5 (timestamp absent)")
    assert_operator md.index("record 5 (timestamp absent)"), :<, md.index("### Tool call")
  end

  def test_oversized_record_fails_before_json_parse_or_archive_write
    path = write_rollout(fixture)
    File.open(path, "ab") { |file| file.write(" " * (CodexSessionImporter::MAX_LINE_BYTES + 1)) }
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "exceeds"
    assert_empty markdown_paths
  end
end
