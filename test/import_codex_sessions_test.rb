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

  def test_root_session_identity_is_distinct_from_subagent_thread_identity
    records = fixture
    root_id = "87654321-4321-4321-4321-cba987654321"
    records.first["payload"]["session_id"] = root_id
    records.first["payload"]["parent_thread_id"] = root_id
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "Session ID: `#{ID}`"
    assert_includes md, "Root Session ID: `#{root_id}`"
    assert_equal 0, run_import.first
  end

  def test_invalid_root_session_id_still_fails_closed
    records = fixture
    records.first["payload"]["session_id"] = "not-a-uuid"
    write_rollout(records)
    code, _, errors = run_import(dry_run: true)
    assert_equal 1, code
    assert_includes errors, "invalid root session ID"
    assert_empty markdown_paths
  end

  def test_thread_settings_event_is_raw_only_and_preserves_existing_markdown
    original = fixture
    write_rollout(original)
    assert_equal 0, run_import.first
    existing_md = File.binread(markdown_paths.fetch(0))
    assert_equal 0, run_import.first
    assert_equal existing_md, File.binread(markdown_paths.fetch(0))

    # In a fresh destination, a Codex settings update does not become a chat message.
    FileUtils.rm_f(raw_path)
    FileUtils.rm_f(markdown_paths.fetch(0))
    records = fixture
    records.insert(3, row("event_msg", { "type" => "thread_settings_applied",
                                          "settings" => { "sandbox_mode" => "read-only" } }))
    path = write_rollout(records)
    assert_equal 0, run_import.first
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    refute_includes md, "thread_settings_applied"
    assert_equal 1, md.scan("Perform a synthetic check.").length
  end

  def test_subagent_activity_is_preserved_as_a_diagnostic
    records = fixture
    child_id = "87654321-4321-4321-4321-cba987654321"
    records.insert(5, row("event_msg", { "type" => "item_completed", "item" => {
      "type" => "SubAgentActivity", "kind" => "completed", "agent_thread_id" => child_id,
      "agent_path" => "1.0", "model" => "synthetic" } }))
    path = write_rollout(records)
    assert_equal 0, run_import.first
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "### Subagent activity"
    assert_includes md, "Kind: `completed`; thread: `#{child_id}`"
    assert_includes md, "Execution diagnostics: 2"
  end

  def test_malformed_subagent_activity_remains_rejected
    records = fixture
    records.insert(5, row("event_msg", { "type" => "item_completed", "item" => {
      "type" => "SubAgentActivity", "kind" => "future_kind", "agent_thread_id" => ID } }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "invalid subagent activity"
    assert_empty markdown_paths
  end

  def test_identical_repeated_session_metadata_is_accepted
    records = fixture
    records.insert(3, records.first.dup)
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    assert_includes File.binread(markdown_paths.fetch(0)), "private/internal records omitted from Markdown: 3"
  end

  def test_ancestor_session_metadata_is_accepted_only_when_named_by_primary_metadata
    records = fixture
    root_id = "87654321-4321-4321-4321-cba987654321"
    records.first["payload"]["session_id"] = root_id
    ancestor = row("session_meta", { "id" => root_id, "session_id" => root_id,
                                      "timestamp" => START, "cwd" => "/tmp/ancestor" })
    records.insert(3, ancestor)
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "Root Session ID: `#{root_id}`"
    assert_includes md, "Working directory: `/tmp/synthetic-project`"
    refute_includes md, "/tmp/ancestor"
  end

  def test_unrelated_repeated_session_metadata_remains_rejected
    records = fixture
    records.insert(3, row("session_meta", { "id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                                                 "session_id" => ID, "timestamp" => START }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "unrelated repeated session_meta"
    assert_empty markdown_paths
  end

  def test_malformed_primary_ancestry_does_not_bypass_identity_check
    records = fixture
    records.first["payload"]["parent_thread_id"] = { "id" => "untrusted" }
    records.insert(3, row("session_meta", { "id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                                                 "timestamp" => START }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "unrelated repeated session_meta"
    assert_empty markdown_paths
  end

  def test_invalid_repeated_root_session_id_remains_rejected
    records = fixture
    records.insert(3, row("session_meta", { "id" => ID, "session_id" => "invalid",
                                                 "timestamp" => START }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "invalid repeated root session ID"
    assert_empty markdown_paths
  end

  def test_inter_agent_communication_metadata_remains_raw_only
    records = fixture
    records.insert(3, row("inter_agent_communication_metadata", { "trigger_turn" => true }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    refute_includes File.binread(markdown_paths.fetch(0)), "inter_agent_communication_metadata"
  end

  def test_malformed_inter_agent_metadata_remains_rejected
    records = fixture
    records.insert(3, row("inter_agent_communication_metadata", { "trigger_turn" => "yes" }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "invalid inter-agent metadata"
    assert_empty markdown_paths
  end

  def test_plain_string_custom_tool_output_is_preserved
    records = fixture(tool: false)
    records.insert(3, row("response_item", { "type" => "custom_tool_call", "call_id" => "call-2",
                                              "name" => "exec", "input" => "test input" }))
    records.insert(4, row("response_item", { "type" => "custom_tool_call_output",
                                              "call_id" => "call-2", "output" => "plain text result" }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    assert_includes File.binread(markdown_paths.fetch(0)), "plain text result"
  end

  def test_structured_function_tool_output_is_preserved
    records = fixture(tool: false)
    records.insert(3, row("response_item", { "type" => "function_call", "call_id" => "call-2",
                                              "name" => "exec", "arguments" => "{}" }))
    records.insert(4, row("response_item", { "type" => "function_call_output",
                                              "call_id" => "call-2",
                                              "output" => [{ "type" => "input_text", "text" => "structured result" }] }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    assert_includes File.binread(markdown_paths.fetch(0)), "structured result"
  end

  def test_object_tool_output_remains_rejected
    records = fixture(tool: false)
    records.insert(3, row("response_item", { "type" => "custom_tool_call", "call_id" => "call-2",
                                              "name" => "exec", "input" => "test input" }))
    records.insert(4, row("response_item", { "type" => "custom_tool_call_output",
                                              "call_id" => "call-2", "output" => { "text" => "unexpected" } }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "unsupported tool result content"
    assert_empty markdown_paths
  end

  def test_object_message_content_remains_rejected
    records = fixture
    records.insert(3, row("response_item", { "type" => "message", "role" => "assistant",
                                              "content" => { "text" => "unexpected" } }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "message content is not an array"
    assert_empty markdown_paths
  end

  def test_compaction_record_remains_raw_only_without_leaking_internal_summary
    records = fixture
    records.insert(3, row("compacted", { "message" => "PRIVATE COMPACTION SUMMARY",
                                         "replacement_history" => [], "window_number" => 1 }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    refute_includes md, "PRIVATE COMPACTION SUMMARY"
    assert_includes md, "private/internal records omitted from Markdown: 3"
    assert_equal 0, run_import.first
  end

  def test_malformed_compaction_still_fails_closed
    records = fixture
    records.insert(3, row("compacted", { "message" => { "not" => "text" } }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "invalid compaction record"
    assert_empty markdown_paths
    assert_empty Dir.glob(File.join(@data, "raw", "**", "*.jsonl"))
  end

  def test_plaintext_agent_message_preserves_sender_recipient_and_order
    records = fixture
    records.insert(3, row("response_item", { "type" => "agent_message",
      "author" => "/root", "recipient" => "/root/child",
      "content" => [{ "type" => "input_text", "text" => "Inspect the patch." }] }))
    # The event message for the same item is a presentation mirror, not a second message.
    records.insert(4, row("event_msg", { "type" => "item_completed", "item" => {
      "type" => "AgentMessage", "content" => [{ "type" => "text", "text" => "Inspect the patch." }] } }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "### Inter-agent message"
    assert_includes md, "From: `/root`; to: `/root/child`"
    assert_equal 1, md.scan("Inspect the patch.").length
    assert_operator md.index("### User"), :<, md.index("### Inter-agent message")
    assert_operator md.index("### Inter-agent message"), :<, md.index("### Assistant")
  end

  def test_encrypted_agent_message_does_not_leak_partially_plaintext_content
    records = fixture
    records.insert(3, row("response_item", { "type" => "agent_message",
      "author" => "/root/child", "recipient" => "/root",
      "content" => [{ "type" => "input_text", "text" => "PRIVATE PARTIAL AGENT TEXT" },
                    { "type" => "encrypted_content", "encrypted_content" => "opaque" }] }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "[encrypted inter-agent message; see raw JSONL]"
    refute_includes md, "PRIVATE PARTIAL AGENT TEXT"
  end

  def test_agent_message_does_not_supply_a_user_title
    records = fixture(heading: "No explicit heading here", tool: false)
    records.insert(3, row("response_item", { "type" => "agent_message",
      "author" => "/root", "recipient" => "/root/child",
      "content" => [{ "type" => "input_text", "text" => "# Should not become title" }] }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal "2026-10-10 - Codex Session 12345678 [12345678].md", File.basename(markdown_paths.fetch(0))
  end

  def test_invalid_agent_message_participants_or_content_fail_closed
    [{ "author" => "", "recipient" => "/root", "content" => [] },
     { "author" => "/root", "recipient" => "/root/child", "content" => "not an array" },
     { "author" => "/root", "recipient" => "/root/child",
       "content" => [{ "type" => "future_secret", "text" => "unknown" }] },
     { "author" => "/root", "recipient" => "/root/child",
       "content" => [{ "type" => "encrypted_content", "encrypted_content" => 123 }] }].each do |body|
      records = fixture
      records.insert(3, row("response_item", { "type" => "agent_message" }.merge(body)))
      write_rollout(records)
      code, _, errors = run_import
      assert_equal 1, code
      assert_match(/agent message/, errors)
      assert_empty markdown_paths
      assert_empty Dir.glob(File.join(@data, "raw", "**", "*.jsonl"))
    end
  end

  def test_inter_agent_routing_record_is_retained_in_raw_without_duplicate_message
    records = fixture
    records.insert(3, row("inter_agent_communication", {
      "author" => "/root", "recipient" => "/root/child", "content" => "ROUTING ONLY",
      "trigger_turn" => false, "other_recipients" => [] }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    refute_includes File.binread(markdown_paths.fetch(0)), "ROUTING ONLY"
  end

  def test_invalid_inter_agent_routing_record_fails_closed
    records = fixture
    records.insert(3, row("inter_agent_communication", {
      "author" => "/root", "recipient" => "/root/child", "content" => "text",
      "trigger_turn" => "no", "other_recipients" => [] }))
    write_rollout(records)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "invalid inter-agent communication"
    assert_empty markdown_paths
  end

  def test_context_compaction_completed_item_is_a_checkpoint_without_private_summary
    records = fixture
    records.insert(3, row("event_msg", { "type" => "item_completed", "item" => {
      "type" => "ContextCompaction", "id" => "checkpoint-1" } }))
    records.insert(4, row("compacted", { "message" => "PRIVATE COMPACTION CONTENT",
                                         "replacement_history" => [] }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "### Context compaction"
    assert_includes md, "Checkpoint: `checkpoint-1`"
    assert_includes md, "Status: complete"
    assert_includes md, "Execution diagnostics: 2"
    refute_includes md, "PRIVATE COMPACTION CONTENT"
    assert_equal 0, run_import.first
  end

  def test_invalid_context_compaction_item_fails_closed
    [nil, 7, ""].each do |invalid_id|
      records = fixture
      records.insert(3, row("event_msg", { "type" => "item_completed", "item" => {
        "type" => "ContextCompaction", "id" => invalid_id } }))
      write_rollout(records)
      code, _, errors = run_import
      assert_equal 1, code
      assert_includes errors, "invalid context compaction item"
      assert_empty markdown_paths
      assert_empty Dir.glob(File.join(@data, "raw", "**", "*.jsonl"))
    end
  end

  def test_turn_abort_preserves_reason_and_does_not_override_session_completion
    records = fixture
    records.insert(3, row("event_msg", { "type" => "turn_aborted",
      "turn_id" => "turn-1", "reason" => "interrupted" }))
    path = write_rollout(records)
    code, _, errors = run_import
    assert_equal 0, code, errors
    assert_equal File.binread(path), File.binread(raw_path)
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "### Turn aborted"
    assert_includes md, "Reason: `interrupted`; turn: `turn-1`"
    assert_includes md, "Status: complete"
    assert_operator md.index("### Turn aborted"), :<, md.index("### Assistant")
    assert_equal 0, run_import.first
  end

  def test_turn_abort_without_turn_id_is_valid
    records = fixture(complete: false)
    records.insert(3, row("event_msg", { "type" => "turn_aborted", "reason" => "replaced" }))
    write_rollout(records)
    assert_equal 0, run_import.first
    md = File.binread(markdown_paths.fetch(0))
    assert_includes md, "Reason: `replaced`. Full details: raw JSONL."
    assert_includes md, "Status: incomplete (no task_complete record)"
  end

  def test_invalid_turn_abort_is_rejected_without_archiving
    [{ "reason" => "unknown" }, { "reason" => "interrupted", "turn_id" => 99 },
     { "reason" => nil }].each do |fields|
      records = fixture
      records.insert(3, row("event_msg", { "type" => "turn_aborted" }.merge(fields)))
      write_rollout(records)
      code, _, errors = run_import
      assert_equal 1, code
      assert_includes errors, "invalid turn abort event"
      assert_empty markdown_paths
      assert_empty Dir.glob(File.join(@data, "raw", "**", "*.jsonl"))
    end
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
  def test_settled_only_skips_today_and_recently_modified_old_sessions
    file = write_rollout(fixture)
    prior_day = Time.local(2026, 10, 10, 19, 0)
    File.utime(prior_day, prior_day, file)
    output = StringIO.new
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
      settled_only: true, now: Time.local(2026, 10, 10, 23, 0), output: output).run
    assert_equal 0, code
    assert_includes output.string, "skipped=1"
    assert_empty markdown_paths

    # A prior-day rollout remains ineligible when recently updated.
    recent = Time.local(2026, 10, 11, 9, 0)
    File.utime(recent, recent, file)
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
      settled_only: true, now: Time.local(2026, 10, 11, 10, 0), output: StringIO.new).run
    assert_equal 0, code
    assert_empty markdown_paths

    output = StringIO.new
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
      settled_only: true, now: Time.local(2026, 10, 11, 12, 0), output: output).run
    assert_equal 0, code
    assert_includes output.string, "imported=1"
    assert_equal File.binread(file), File.binread(raw_path)
  end

  def test_settled_only_works_as_a_dry_run_and_reports_skips
    file = write_rollout(fixture)
    old = Time.local(2026, 10, 10, 19, 0)
    File.utime(old, old, file)
    out = StringIO.new
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
      settled_only: true, now: Time.local(2026, 10, 11, 12, 0),
      dry_run: true, output: out).run
    assert_equal 0, code
    assert_includes out.string, "imported=1"
    assert_empty markdown_paths
    assert_empty Dir.glob(File.join(@data, "raw", "**", "*.jsonl"))
  end

  def test_settled_only_rejects_unparseable_source_date
    file = write_rollout(fixture)
    File.rename(file, File.join(@source, "rollout-unknown-#{ID}.jsonl"))
    output = StringIO.new
    errors = StringIO.new
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
      settled_only: true, now: Time.local(2026, 10, 11, 12, 0),
      output: output, errors: errors).run
    assert_equal 1, code
    assert_includes errors.string, "unrecognized rollout date"
    assert_empty markdown_paths
  end

  def test_colliding_short_ids_use_distinct_full_ids_in_dry_run_and_real_import
    other_id = "12345678-8765-4321-1234-abcdefabcdef"
    first = write_rollout(fixture)
    second = write_rollout(fixture(id: other_id), id: other_id)
    output = StringIO.new
    code = CodexSessionImporter.new(source: @source, data_repo: @data,
      dry_run: true, output: output).run
    assert_equal 0, code
    assert_includes output.string, "imported=2"
    assert_includes output.string, "[#{ID}].md"
    assert_includes output.string, "[#{other_id}].md"
    assert_empty markdown_paths

    assert_equal 0, run_import.first
    assert_equal File.binread(first), File.binread(raw_path)
    assert_equal File.binread(second), File.binread(raw_path(other_id))
    assert_equal 2, markdown_paths.length
    assert markdown_paths.all? { |path| path.include?("[12345678-") }
    code, out, errors = run_import
    assert_equal 0, code, errors
    assert_includes out, "unchanged=2"
  end

  def test_legacy_short_name_stays_unchanged_after_new_collision_is_discovered
    first = write_rollout(fixture)
    assert_equal 0, run_import.first
    legacy = markdown_paths.fetch(0)
    assert_includes legacy, "[12345678].md"
    previous = File.binread(legacy)

    other_id = "12345678-8765-4321-1234-abcdefabcdef"
    second = write_rollout(fixture(id: other_id), id: other_id)
    code, out, errors = run_import(dry_run: true)
    assert_equal 0, code, errors
    assert_includes out, "unchanged=1"
    assert_includes out, "imported=1"
    assert_includes out, "[#{other_id}].md"

    assert_equal 0, run_import.first
    assert_equal previous, File.binread(legacy)
    assert_equal File.binread(first), File.binread(raw_path)
    assert_equal File.binread(second), File.binread(raw_path(other_id))
    assert_equal 2, markdown_paths.length
    assert_equal 0, run_import.first
  end

  def test_existing_legacy_markdown_with_same_id_cannot_be_bypassed
    write_rollout(fixture)
    assert_equal 0, run_import.first
    legacy = markdown_paths.fetch(0)
    File.open(legacy, "ab") { |file| file.write("user edit\n") }
    other_id = "12345678-8765-4321-1234-abcdefabcdef"
    write_rollout(fixture(id: other_id), id: other_id)
    code, _, errors = run_import
    assert_equal 1, code
    assert_includes errors, "different existing Markdown"
    assert_equal 1, markdown_paths.grep(/\[12345678\]\.md$/).length
  end
end
