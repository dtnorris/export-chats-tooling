#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"

class CaptureWatchError < StandardError; end

STATE_DIR = File.expand_path(".state", __dir__)
DEFAULT_DATA_REPO = File.expand_path("../export-chats-data", __dir__)
DEFAULT_DOWNLOAD_DIR = File.expand_path(ENV.fetch("CHAT_EXPORT_DOWNLOAD_DIR", "~/Downloads"))
CAPTURE_GLOB = "AFCHAT_*.json"
CAPTURE_SCHEMA = "adventurefinder-chat-download-capture/v0.1"
POLL_SECONDS = 1.0

class CaptureWatch
  def initialize(data_repo:, download_dir:, once: false)
    @data_repo = File.expand_path(data_repo)
    @download_dir = File.expand_path(download_dir)
    @once = once
    @queue_path = File.join(STATE_DIR, "pending_ids.json")
    @status_path = File.join(STATE_DIR, "capture_status.json")
    @stable = {}

    raise CaptureWatchError, "data repo does not exist: #{@data_repo}" unless Dir.exist?(@data_repo)
    raise CaptureWatchError, "download directory does not exist: #{@download_dir}" unless Dir.exist?(@download_dir)
    raise CaptureWatchError, "pending queue missing; run reconcile_exports.rb first" unless File.file?(@queue_path)

    @queue = JSON.parse(File.binread(@queue_path))
    @project_id = @queue.fetch("project_id")
    @queue_by_id = @queue.fetch("pending").to_h { |entry| [entry.fetch("id"), entry] }
    @status = load_status
    reconcile_existing_raw!
    persist_status!
  end

  def run
    puts "AdventureFinder capture download watcher"
    puts "Downloads: #{@download_dir}"
    puts "Data repo: #{@data_repo}"
    puts "Project:   #{@project_id}"
    puts "Queued:    #{@queue_by_id.length}"
    puts "Completed: #{@status.fetch("completed").length}"
    puts

    if @once
      scan_once
      sleep 0.05
      scan_once
      return
    end

    loop do
      scan_once
      sleep POLL_SECONDS
    end
  rescue Interrupt
    puts "\nCapture watcher stopped."
  end

  private

  def scan_once
    paths = Dir.glob(File.join(@download_dir, CAPTURE_GLOB)).sort
    live = paths.to_h { |path| [path, true] }
    @stable.delete_if { |path, _| !live.key?(path) }

    paths.each do |path|
      size = File.size(path)
      prior = @stable[path]
      if prior && prior.fetch(:size) == size
        prior[:stable_scans] += 1
      else
        @stable[path] = { size: size, stable_scans: 0 }
      end

      next unless @stable.fetch(path).fetch(:stable_scans) >= 1

      process_capture!(path)
      @stable.delete(path)
    rescue JSON::ParserError => e
      warn "capture watcher: invalid JSON left in place: #{path}: #{e.message}"
      @stable.delete(path)
    rescue CaptureWatchError => e
      warn "capture watcher: rejected capture left in place: #{path}: #{e.message}"
      @stable.delete(path)
    end
  end

  def process_capture!(path)
    payload = JSON.parse(File.binread(path))
    raise CaptureWatchError, "schema mismatch" unless payload["schema"] == CAPTURE_SCHEMA
    raise CaptureWatchError, "project mismatch" unless payload.fetch("project_id") == @project_id

    id = payload.fetch("conversation_id")
    queued = @queue_by_id[id]
    raise CaptureWatchError, "conversation is not in the reconciled pending queue: #{id}" unless queued

    raw = payload.fetch("raw")
    markdown = payload.fetch("markdown")
    message_count = payload.fetch("message_count")
    title = payload["title"] || queued["title"] || "Chat Export"
    date = normalize_date(payload["create_date"])

    raise CaptureWatchError, "raw conversation must be an object" unless raw.is_a?(Hash)
    raise CaptureWatchError, "markdown must be a non-empty string" unless markdown.is_a?(String) && !markdown.empty?
    raise CaptureWatchError, "message_count must be a positive integer" unless message_count.is_a?(Integer) && message_count.positive?

    embedded_id = raw["id"] || raw["conversation_id"]
    if embedded_id && embedded_id != id
      raise CaptureWatchError, "raw conversation ID #{embedded_id.inspect} does not match queued ID #{id.inspect}"
    end

    raw_path = File.join(@data_repo, "raw", "#{id}.json")
    md_name = "#{date} - #{safe_filename_part(title)} [#{id[0, 8]}].md"
    md_path = File.join(@data_repo, md_name)

    raw_text = JSON.pretty_generate(raw) + "\n"
    markdown_text = markdown.end_with?("\n") ? markdown : "#{markdown}\n"
    write_idempotent!(raw_path, raw_text)
    write_idempotent!(md_path, markdown_text)

    @status.fetch("completed")[id] = {
      "captured_at" => payload["captured_at"] || Time.now.utc.iso8601,
      "ingested_at" => Time.now.utc.iso8601,
      "title" => title,
      "message_count" => message_count,
      "raw_path" => relative_to_data_repo(raw_path),
      "markdown_path" => relative_to_data_repo(md_path),
      "raw_sha256" => Digest::SHA256.hexdigest(raw_text),
      "markdown_sha256" => Digest::SHA256.hexdigest(markdown_text)
    }
    @status.fetch("failures").delete(id)
    persist_status!

    File.delete(path)
    puts "Captured #{id} -> #{relative_to_data_repo(md_path)}"
  end

  def reconcile_existing_raw!
    raw_dir = File.join(@data_repo, "raw")
    return unless Dir.exist?(raw_dir)

    Dir.glob(File.join(raw_dir, "*.json")).each do |path|
      id = File.basename(path, ".json")
      next unless @queue_by_id.key?(id)
      next if @status.fetch("completed").key?(id)

      raw = JSON.parse(File.binread(path))
      embedded_id = raw["id"] || raw["conversation_id"]
      if embedded_id && embedded_id != id
        raise CaptureWatchError, "existing raw capture ID mismatch: #{path}"
      end

      @status.fetch("completed")[id] = {
        "captured_at" => nil,
        "ingested_at" => nil,
        "title" => @queue_by_id.fetch(id)["title"],
        "message_count" => nil,
        "raw_path" => relative_to_data_repo(path),
        "markdown_path" => nil,
        "raw_sha256" => Digest::SHA256.file(path).hexdigest,
        "markdown_sha256" => nil,
        "recovered_from_disk" => true
      }
    end
  end

  def load_status
    if File.file?(@status_path)
      parsed = JSON.parse(File.binread(@status_path))
      if parsed["project_id"] != @project_id
        raise CaptureWatchError, "capture_status.json belongs to a different project"
      end
      parsed["completed"] ||= {}
      parsed["failures"] ||= {}
      return parsed
    end

    {
      "schema" => "adventurefinder-chat-capture-status/v0.2",
      "project_id" => @project_id,
      "created_at" => Time.now.utc.iso8601,
      "updated_at" => Time.now.utc.iso8601,
      "completed" => {},
      "failures" => {}
    }
  end

  def persist_status!
    @status["updated_at"] = Time.now.utc.iso8601
    FileUtils.mkdir_p(STATE_DIR)
    atomic_write(@status_path, JSON.pretty_generate(@status) + "\n")
  end

  def write_idempotent!(path, content)
    if File.exist?(path)
      existing = File.binread(path)
      return if existing == content
      raise CaptureWatchError, "refusing to overwrite different existing file: #{path}"
    end

    FileUtils.mkdir_p(File.dirname(path))
    atomic_write(path, content)
  end

  def atomic_write(path, content)
    temp = "#{path}.tmp-#{Process.pid}"
    File.binwrite(temp, content)
    File.rename(temp, path)
  ensure
    File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
  end

  def normalize_date(value)
    return value if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    Time.now.getlocal.strftime("%Y-%m-%d")
  end

  def safe_filename_part(value)
    result = value.to_s
      .gsub(/[<>:\"\/\\|?*\u0000-\u001f]/, "-")
      .gsub(/\s+/, " ")
      .strip
      .sub(/[. ]+\z/, "")
      .slice(0, 160)
    result.nil? || result.empty? ? "Chat Export" : result
  end

  def relative_to_data_repo(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@data_repo)).to_s
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  once = args.delete("--once")
  data_repo = args[0] || DEFAULT_DATA_REPO
  download_dir = args[1] || DEFAULT_DOWNLOAD_DIR

  begin
    CaptureWatch.new(data_repo: data_repo, download_dir: download_dir, once: !once.nil?).run
  rescue CaptureWatchError, Errno::ENOENT, JSON::ParserError => e
    warn "CAPTURE WATCH FAILED: #{e.message}"
    exit 1
  end
end
