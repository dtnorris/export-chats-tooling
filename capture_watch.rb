#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "reconcile_exports"

class CaptureWatchError < StandardError; end

DEFAULT_DOWNLOAD_DIR = File.expand_path(ENV.fetch("CHAT_EXPORT_DOWNLOAD_DIR", "~/Downloads"))
CAPTURE_GLOB = "AFCHAT_*.json"
POLL_SECONDS = 1.0

# Ingest complete browser packages with a matching trusted queue. Downloads remain
# recoverable until bundle, observation, current index and local checkpoint verify.
# Single watcher per tooling checkout; errors leave packages in place.
class CaptureWatch
  # Read explicit archive/download/state paths and an optional one-pass flag.
  # Raises on invalid queue/binding or filesystem errors; never trusts old status.
  def initialize(data_repo:, download_dir:, once: false, state_dir: STATE_DIR, fault: nil)
    @data_repo = File.expand_path(data_repo)
    @download_dir = File.expand_path(download_dir)
    @state_dir = File.expand_path(state_dir)
    @once = once
    @fault = fault
    @stable = {}
    raise CaptureWatchError, "download directory does not exist" unless Dir.exist?(@download_dir)
    current = @download_dir
    loop do
      raise CaptureWatchError, "download directory symlink refused" if File.symlink?(current)
      break if current == "/"
      current = File.dirname(current)
    end
    @queue = SnapshotArchive.queue!(SnapshotArchive.parse(File.binread(state_path!("pending_ids.json"))))
    @archive = SnapshotArchive.new(root: @data_repo, project_id: @queue["project_id"], account_id: @queue["account_id"])
    @status = { "schema" => "adventurefinder-chat-capture-status/v0.3", "project_id" => @queue["project_id"],
      "account_id" => @queue["account_id"], "queue_sha256" => @queue["sha256"], "completed" => {}, "ingested" => {} }
    # Old completion entries and raw-only files never authorize success. Complete
    # journal entries can repair an interrupted derived index/checkpoint.
    @queue["pending"].each do |entry|
      current = @archive.current!(entry["id"], repair: true)
      record_status(entry["id"], current) if current
    end
    persist_status!
  end

  # Poll stable downloads sequentially, or scan twice for --once. Returns nil;
  # Ctrl-C leaves filesystem operations replayable through retained downloads.
  def run
    puts "Capture watcher: #{@queue["project_id"]}; #{@queue["pending"].length} queued; downloads #{@download_dir}"
    loop do
      scan_once
      break if @once && @scanned
      @scanned = true
      sleep(@once ? 0.05 : POLL_SECONDS)
    end
  rescue Interrupt
    puts "\nCapture watcher stopped."
  end

  private

  # Inspect sizes on consecutive polls; process only stable regular downloads.
  # Rejections/errors remain on disk, with no completion acknowledgement.
  def scan_once
    paths = Dir.glob(File.join(@download_dir, CAPTURE_GLOB)).sort
    @stable.delete_if { |path, _| !paths.include?(path) }
    paths.each do |path|
      raise CaptureWatchError, "symlink/non-file download refused" if File.symlink?(path) || !File.file?(path)
      size = File.size(path)
      prior = @stable[path]
      @stable[path] = size
      next unless prior == size
      process_capture!(path)
      @stable.delete(path)
    rescue SnapshotArchiveError, CaptureWatchError, JSON::ParserError, SystemCallError, KeyError, TypeError => error
      warn "capture watcher: rejected/incomplete download left in place: #{path}: #{error.message}"
      @stable.delete(path)
    end
  end

  # Ingest one package, verify current and checkpoint, then remove it. Returns its
  # current observation; exceptions (including injected faults) retain the download.
  def process_capture!(path)
    raise CaptureWatchError, "unsafe download" if File.symlink?(path) || File.dirname(File.expand_path(path)) != @download_dir
    text = File.binread(path)
    @archive.ingest(text, @queue, fault: @fault)
    id = JSON.parse(text).fetch("conversation_id")
    current = @archive.current!(id)
    raise CaptureWatchError, "complete current version required" unless current
    record_status(id, current)
    @fault&.call("before_checkpoint")
    persist_status!
    @fault&.call("after_checkpoint")
    verified = SnapshotArchive.verify!(JSON.parse(File.binread(state_path!("capture_status.json"))))
    raise CaptureWatchError, "checkpoint verification failed" unless verified["ingested"][id] == current
    File.delete(path)
    puts "Ingested #{id} version #{current["version"]} (#{current["freshness"]})"
    current
  end

  # Record complete content separately from freshness; unresolved captures are
  # ingested evidence, never marked complete against a listing.
  def record_status(id, current)
    @status["ingested"][id] = current
    @status["completed"].delete(id)
    entry = @queue["pending"].find { |candidate| candidate["id"] == id }
    if current["freshness"] == "verified-as-listed" && entry.dig("listing", "update_time_status") == "valid" &&
        entry.dig("listing", "update_time") == current.dig("listing", "update_time")
      @status["completed"][id] = current
    end
  end

  # Resolve fixed state filenames and reject symlink components. Returns absolute
  # path or raises before queue/checkpoint filesystem access.
  def state_path!(name)
    path = File.join(@state_dir, name)
    current = path
    loop do
      raise CaptureWatchError, "state symlink refused" if File.symlink?(current)
      break if current == "/"
      current = File.dirname(current)
    end
    path
  end

  # Atomically fsync the derived checkpoint after full bundle verification.
  # Errors propagate and leave the download for recovery.
  def persist_status!
    path = state_path!("capture_status.json")
    FileUtils.mkdir_p(@state_dir)
    temp = "#{path}.tmp-#{SecureRandom.hex(8)}"
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(SnapshotArchive.seal(@status)) + "\n")
      file.fsync
    end
    File.rename(temp, path)
    @archive.sync_directory(@state_dir)
  ensure
    File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
  end
end

if $PROGRAM_NAME == __FILE__
  args = ARGV.dup
  once = args.delete("--once")
  begin
    CaptureWatch.new(data_repo: args[0] || DEFAULT_DATA_REPO,
      download_dir: args[1] || DEFAULT_DOWNLOAD_DIR, once: !once.nil?).run
  rescue CaptureWatchError, SnapshotArchiveError, SystemCallError, JSON::ParserError => error
    warn "CAPTURE WATCH FAILED: #{error.message}"
    exit 1
  end
end
