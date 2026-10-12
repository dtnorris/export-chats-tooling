#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "date"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "tempfile"
require "time"

# Codex rollouts are evidence, not ChatGPT conversation API responses. Keep their
# identity and original bytes in a separate namespace.
class CodexImportError < StandardError; end

class CodexSessionImporter
  DEFAULT_SOURCE = File.expand_path("~/.codex/sessions")
  DEFAULT_DATA_REPO = File.expand_path("../export-chats-data", __dir__)
  ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  MAX_LINE_BYTES = 16 * 1024 * 1024

  def initialize(source:, data_repo:, dry_run: false, verbose: false, output: $stdout, errors: $stderr)
    @source = File.realpath(File.expand_path(source))
    @data_repo = File.realpath(File.expand_path(data_repo))
    raise CodexImportError, "source is not a directory" unless File.directory?(@source)
    raise CodexImportError, "data repo is not a directory" unless File.directory?(@data_repo)
    raise CodexImportError, "source and destination overlap" if inside?(@source, @data_repo) || inside?(@data_repo, @source)

    @dry_run, @verbose, @output, @errors = dry_run, verbose, output, errors
  rescue Errno::ENOENT => e
    raise CodexImportError, "missing source or destination directory: #{e.message}"
  end

  def run
    paths = Dir.glob(File.join(@source, "**", "rollout-*.jsonl")).sort
    counts = { discovered: paths.length, imported: 0, unchanged: 0, skipped: 0, failed: 0, conflicting: 0 }
    # Preflight identities across the entire discovery set before writing anything.
    identities = Hash.new { |hash, key| hash[key] = [] }
    paths.each do |path|
      begin
        safe_source!(path)
        identities[identity_from_first_record(path)] << path
      rescue CodexImportError, SystemCallError => e
        counts[:failed] += 1
        @errors.puts "FAILED #{path}: #{e.message}"
      end
    end
    duplicates = identities.select { |_id, files| files.length > 1 }
    duplicates.each do |id, files|
      counts[:conflicting] += files.length
      @errors.puts "CONFLICT duplicate session ID #{id}: #{files.join(', ')}"
    end

    identities.each do |id, files|
      next if duplicates.key?(id)

      path = files.first
      begin
        session = parse(path)
        raise CodexImportError, "session ID changed while reading" unless session[:id] == id
        result, raw_path, md_path = install(session, path)
        counts[result] += 1
        @output.puts "#{result.to_s.upcase} #{id} -> #{relative(md_path)} (#{relative(raw_path)})" if @verbose || result != :unchanged
      rescue CodexImportError, SystemCallError, JSON::ParserError, ArgumentError => e
        counts[:failed] += 1
        @errors.puts "FAILED #{path}: #{e.message}"
      end
    end
    @output.puts "Codex sessions: #{counts.map { |key, value| "#{key}=#{value}" }.join(' ')}#{@dry_run ? ' (dry-run)' : ''}"
    counts[:failed].zero? && counts[:conflicting].zero? ? 0 : 1
  end

  private

  def inside?(path, root)
    path == root || path.start_with?("#{root}/")
  end

  def safe_source!(path)
    relative = Pathname.new(path).relative_path_from(Pathname.new(@source)).to_s
    cursor = @source
    relative.split(File::SEPARATOR).each do |part|
      cursor = File.join(cursor, part)
      raise CodexImportError, "symlink in source path: #{path}" if File.lstat(cursor).symlink?
    end
    raise CodexImportError, "source escapes root" unless inside?(File.realpath(path), @source)
    raise CodexImportError, "source is not a regular file" unless File.file?(path)
  end

  def identity_from_first_record(path)
    File.open(path, "rb") do |file|
      line = file.gets(MAX_LINE_BYTES + 1)
      raise CodexImportError, "empty session" unless line
      raise CodexImportError, "oversized record" if line.bytesize > MAX_LINE_BYTES
      row = JSON.parse(line)
      raise CodexImportError, "first record is not session_meta" unless row.is_a?(Hash) && row["type"] == "session_meta"
      meta = row["payload"]
      id = meta.is_a?(Hash) && meta["id"]
      raise CodexImportError, "missing or unsafe session ID" unless id.is_a?(String) && ID.match?(id)
      raise CodexImportError, "inconsistent session IDs" if meta["session_id"] && meta["session_id"] != id
      id.downcase
    end
  rescue JSON::ParserError => e
    raise CodexImportError, "invalid first JSON record: #{e.message}"
  end

  def parse(path)
    digest = Digest::SHA256.new
    parts = []
    calls = {}
    users = []
    meta = nil
    lifecycle = "incomplete (no task_complete record)"
    private_count = 0
    diagnostic_count = 0
    record_count = 0
    before = File.stat(path)

    File.open(path, "rb") do |file|
      while (line = file.gets(MAX_LINE_BYTES + 1))
        record_count += 1
        raise CodexImportError, "record #{record_count} exceeds #{MAX_LINE_BYTES} bytes" if line.bytesize > MAX_LINE_BYTES
        digest.update(line)
        begin
          row = JSON.parse(line)
        rescue JSON::ParserError => e
          raise CodexImportError, "invalid JSON at record #{record_count}: #{e.message}"
        end
        raise CodexImportError, "record #{record_count} is not an object" unless row.is_a?(Hash) && row["payload"].is_a?(Hash)
        payload = row["payload"]
        stamp = row["timestamp"]
        label = stamp.is_a?(String) ? stamp : "record #{record_count} (timestamp absent)"

        case row["type"]
        when "session_meta"
          raise CodexImportError, "multiple session_meta records" if meta || record_count != 1
          meta = payload
        when "response_item"
          case payload["type"]
          when "message"
            role = payload["role"]
            if role == "developer" || role == "system" || (role == "assistant" && %w[analysis summary].include?(payload["phase"]))
              private_count += 1
              next
            end
            raise CodexImportError, "unexpected message role: #{role.inspect}" unless %w[user assistant].include?(role)
            body = content(payload["content"])
            users << body if role == "user"
            phase = payload["phase"]
            parts << "### #{role == 'user' ? 'User' : 'Assistant'}#{phase ? " (#{phase})" : ''} — #{label}\n\n#{quoted(body)}\n"
          when "custom_tool_call", "function_call"
            id = payload["call_id"]
            raise CodexImportError, "missing or repeated tool call ID" unless id.is_a?(String) && !id.empty? && !calls.key?(id)
            calls[id] = payload["name"].to_s
            arguments = payload["type"] == "function_call" ? payload["arguments"] : payload["input"]
            if payload["type"] == "function_call" && !arguments.is_a?(String)
              raise CodexImportError, "function call arguments are not a string"
            end
            parts << "### Tool call: #{escape(payload['name'])} — #{label}\n\nCall ID: `#{escape(id)}`\n\n#{details('Arguments', arguments)}\n"
          when "custom_tool_call_output", "function_call_output"
            id = payload["call_id"]
            raise CodexImportError, "tool result without preceding call: #{id.inspect}" unless calls.key?(id)
            name = calls.delete(id)
            result = if payload["type"] == "function_call_output"
              output = payload["output"]
              raise CodexImportError, "function call output is not a string" unless output.is_a?(String)
              output
            else
              content(payload["output"])
            end
            parts << "### Tool result: #{escape(name)} — #{label}\n\nCall ID: `#{escape(id)}`\n\n#{details('Result', result)}\n"
          when "reasoning"
            private_count += 1
          else
            raise CodexImportError, "unsupported response item: #{payload['type'].inspect}"
          end
        when "event_msg"
          case payload["type"]
          when "task_complete"
            lifecycle = "complete"
            parts << "### Task complete — #{label}\n"
          when "task_failed", "task_interrupted", "task_aborted"
            lifecycle = payload["type"].delete_prefix("task_")
            parts << "### #{escape(payload['type'])} — #{label}\n"
          when "item_completed"
            item = payload["item"]
            raise CodexImportError, "item_completed without item" unless item.is_a?(Hash)
            diagnostic = execution_diagnostic(item, label)
            if diagnostic
              parts << diagnostic
              diagnostic_count += 1
            end
          when "task_started", "token_count"
            # Lifecycle start and accounting are present in the raw rollout.
          else
            raise CodexImportError, "unsupported event message: #{payload['type'].inspect}"
          end
        when "turn_context", "world_state", "token_usage_record"
          # Execution context and accounting are recoverable from the raw JSONL.
        else
          raise CodexImportError, "unsupported top-level record: #{row['type'].inspect}"
        end
      end
    end
    raise CodexImportError, "missing session_meta" unless meta
    id = meta["id"]
    raise CodexImportError, "missing or unsafe session ID" unless id.is_a?(String) && ID.match?(id)
    raise CodexImportError, "inconsistent session IDs" if meta["session_id"] && meta["session_id"] != id
    raise CodexImportError, "session filename ID differs from metadata" if File.basename(path) =~ /([0-9a-f-]{36})\.jsonl\z/i && Regexp.last_match(1).downcase != id.downcase
    started = Time.iso8601(meta.fetch("timestamp"))
    filename_date = File.basename(path)[/\Arollout-(\d{4}-\d{2}-\d{2})T/, 1]
    date = filename_date || started.utc.strftime("%Y-%m-%d")
    raise CodexImportError, "source filename date disagrees with session start" if (Date.iso8601(date) - started.utc.to_date).abs > 1
    after = File.stat(path)
    raise CodexImportError, "session changed during read" unless before.size == after.size && before.mtime == after.mtime && before.ino == after.ino

    title = title_from(users, id)
    raw_rel = "raw/codex/#{id.downcase}.jsonl"
    md_name = "#{date} - #{safe_title(title)} [#{id[0, 8].downcase}].md"
    git = meta["git"].is_a?(Hash) ? meta["git"] : {}
    header = <<~MARKDOWN
      # #{title}

      - Source: Codex rollout JSONL
      - Session ID: `#{id}`
      - Started: `#{started.iso8601(3)}`
      - Source date: `#{date}` (rollout filename; UTC timestamp above)
      - Status: #{lifecycle}
      - Working directory: `#{escape(meta['cwd'])}`
      - Repository: `#{escape(git['repository_url'])}`; branch `#{escape(git['branch'])}`; commit `#{escape(git['commit_hash'])}`
      - Source file: `#{escape(Pathname.new(path).relative_path_from(Pathname.new(@source)).to_s)}`
      - Raw archive: `#{raw_rel}`
      - Raw SHA-256: `#{digest.hexdigest}` (#{after.size} bytes, #{record_count} records)
      - Execution diagnostics: #{diagnostic_count}; private/internal records omitted from Markdown: #{private_count}

      The raw JSONL is authoritative. This view omits internal reasoning and developer messages.

      ## Timeline

    MARKDOWN
    parts << "\nUnanswered tool calls: #{calls.keys.map { |key| "`#{escape(key)}`" }.join(', ')}\n" unless calls.empty?
    { id: id.downcase, raw_rel: raw_rel, md_name: md_name, digest: digest.hexdigest,
      markdown: header + parts.join("\n") + "\n" }
  rescue KeyError, TypeError, RangeError => e
    raise CodexImportError, "invalid session metadata: #{e.message}"
  end

  def content(items)
    raise CodexImportError, "message content is not an array" unless items.is_a?(Array)
    items.map do |item|
      raise CodexImportError, "message content item is not an object" unless item.is_a?(Hash)
      if %w[text input_text output_text].include?(item["type"]) && item["text"].is_a?(String)
        item["text"]
      else
        "[non-text #{item['type'].inspect}; see raw JSONL]"
      end
    end.join("\n")
  end

  def execution_diagnostic(item, label)
    case item["type"]
    when "CommandExecution"
      "### Command execution — #{label}\n\nStatus: `#{escape(item['status'])}`; exit: `#{escape(item['exit_code'])}`; cwd: `#{escape(item['cwd'])}`.\n\n#{details('Command', JSON.generate(item['command']))}\n"
    when "FileChange"
      changes = item["changes"].is_a?(Hash) ? item["changes"].keys : []
      "### File change — #{label}\n\nStatus: `#{escape(item['status'])}`; paths: #{changes.map { |name| "`#{escape(name)}`" }.join(', ')}. Full change record: raw JSONL.\n"
    when "McpToolCall"
      "### Nested tool execution — #{label}\n\n`#{escape(item['server'])}.#{escape(item['tool'])}` status: `#{escape(item['status'])}`. Arguments and result: enclosing tool call/result and raw JSONL.\n"
    when "Extension"
      "### Extension activity — #{label}\n\nKind: `#{escape(item['kind'])}`. Query/action and results: enclosing tool call/result and raw JSONL.\n"
    when "UserMessage", "AgentMessage", "Reasoning"
      nil # These mirror response items; reasoning stays private.
    else
      raise CodexImportError, "unsupported completed item: #{item['type'].inspect}"
    end
  end

  def title_from(users, id)
    users.reverse_each do |body|
      heading = body.lines.map(&:strip).find { |line| line.match?(/\A\#{1,3}\s+\S/) }
      next unless heading
      title = heading.sub(/\A\#{1,3}\s+/, "").strip
      return title[0, 120] unless title.empty?
    end
    "Codex Session #{id[0, 8]}"
  end

  def safe_title(title)
    cleaned = title.unicode_normalize(:nfc).gsub(/[<>:\"\/\\|?*\u0000-\u001f]/, "-")
      .gsub(/\s+/, " ").strip.sub(/[. ]+\z/, "")[0, 120]
    cleaned.empty? ? "Codex Session" : cleaned
  end

  def escape(value)
    CGI.escapeHTML(value.to_s).gsub("`", "&#96;")
  end

  def quoted(body)
    body.lines.map { |line| "> #{line.chomp}\n" }.join
  end

  def details(label, body)
    "<details><summary>#{escape(label)}</summary>\n\n<pre>#{CGI.escapeHTML(body.to_s)}</pre>\n\n</details>"
  end

  def relative(path)
    Pathname.new(path).relative_path_from(Pathname.new(@data_repo)).to_s
  end

  def safe_destination!(path)
    raise CodexImportError, "destination escapes data repo" unless inside?(path, @data_repo)
    cursor = @data_repo
    relative(path).split(File::SEPARATOR).each do |part|
      cursor = File.join(cursor, part)
      next unless File.exist?(cursor) || File.symlink?(cursor)
      raise CodexImportError, "symlink in destination: #{cursor}" if File.lstat(cursor).symlink?
    end
  end

  def install(session, source_path)
    raw = File.join(@data_repo, session[:raw_rel])
    md = File.join(@data_repo, session[:md_name])
    [raw, md].each { |path| safe_destination!(path) }
    raw_exists = File.exist?(raw)
    md_exists = File.exist?(md)
    if raw_exists && Digest::SHA256.file(raw).hexdigest != session[:digest]
      raise CodexImportError, "same-ID raw content changed; inspect and resolve explicitly: #{relative(raw)}"
    end
    if md_exists && File.binread(md) != session[:markdown].b
      raise CodexImportError, "different existing Markdown or filename collision: #{relative(md)}"
    end
    return [:unchanged, raw, md] if raw_exists && md_exists
    return [:imported, raw, md] if @dry_run

    FileUtils.mkdir_p(File.dirname(raw))
    safe_destination!(raw)
    unless raw_exists
      # Copy through an isolated temporary file and verify the exact parsed bytes.
      Tempfile.create([".codex-import-", ".jsonl"], File.dirname(raw)) do |temp|
        File.open(source_path, "rb") { |input| IO.copy_stream(input, temp) }
        temp.flush
        temp.fsync
        raise CodexImportError, "source changed before archival copy" unless Digest::SHA256.file(temp.path).hexdigest == session[:digest]
        File.link(temp.path, raw) # Atomic and exclusive; never replaces another writer's file.
      end
    end
    FileUtils.mkdir_p(File.dirname(md))
    safe_destination!(md)
    unless md_exists
      Tempfile.create([".codex-import-", ".md"], File.dirname(md)) do |temp|
        temp.write(session[:markdown])
        temp.flush
        temp.fsync
        File.link(temp.path, md)
      end
    end
    [:imported, raw, md]
  rescue Errno::EEXIST => e
    raise CodexImportError, "destination appeared during import: #{e.message}"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { source: CodexSessionImporter::DEFAULT_SOURCE,
              data_repo: CodexSessionImporter::DEFAULT_DATA_REPO,
              dry_run: false, verbose: false }
  parser = OptionParser.new do |cli|
    cli.banner = "Usage: ruby import_codex_sessions.rb [--source DIR] [--data-repo DIR] [--dry-run] [--verbose]"
    cli.on("--source DIR", "Recursively search Codex rollouts") { |value| options[:source] = value }
    cli.on("--data-repo DIR", "Existing private archive directory") { |value| options[:data_repo] = value }
    cli.on("--dry-run", "Report actions without changing the archive") { options[:dry_run] = true }
    cli.on("--verbose", "Also list unchanged sessions") { options[:verbose] = true }
    cli.on("--help", "Show this help") { puts cli; exit 0 }
  end
  begin
    parser.parse!
    raise CodexImportError, "unexpected positional arguments: #{ARGV.join(' ')}" unless ARGV.empty?
    exit CodexSessionImporter.new(**options).run
  rescue CodexImportError, OptionParser::ParseError => e
    warn "CODEX IMPORT FAILED: #{e.message}"
    exit 1
  end
end
