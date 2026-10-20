#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "reconcile_exports"

# Materialize searchable, title-bearing copies of verified current ChatGPT Markdown.
# Immutable content-addressed versions remain authoritative. Each copy is additive;
# missing copies can be recreated, while conflicting existing files are refused.
class NamedExports
  # Accept a bound SnapshotArchive; all reads and writes use its guarded paths.
  def initialize(archive)
    @archive = archive
  end

  # Write the current version's Markdown as a descriptive file and return its
  # relative path. Raises SnapshotArchiveError on missing/corrupt current evidence,
  # unsafe paths, or different existing bytes.
  def write!(id)
    current = @archive.current!(id)
    raise SnapshotArchiveError, "no verified current capture for #{id}" unless current

    version = current.fetch("version")
    @archive.version!(id, version)
    source = "versions/#{id}/#{version}"
    raw = SnapshotArchive.parse(File.binread(@archive.path!("#{source}/raw.json")))
    markdown = File.binread(@archive.path!("#{source}/conversation.md"))
    title = [raw["title"], current.dig("listing", "title")].find { |value| value.is_a?(String) && !value.strip.empty? }
    title = safe_title(title || "Untitled Chat")
    created = ReconcileHelpers.inventory_timestamp(raw["create_time"])
    created = ReconcileHelpers.inventory_timestamp(current.dig("listing", "create_time")) unless created[:status] == "valid"
    date = created[:status] == "valid" ? created[:value][0, 10] : "captured-#{current.fetch('captured_at')[0, 10]}"
    name = "#{date} - #{title} [#{id[0, 8]}-#{version[0, 12]}].md"
    relative = "named/#{name}"
    @archive.immutable!(relative, markdown)
    relative
  end

  # Restore missing readable copies for all currently verified conversation IDs.
  # Returns the list of paths; a conflict raises without replacing any prior file.
  def backfill!
    Dir.children(@archive.path!("versions")).sort.filter_map do |id|
      next if id.start_with?(".") || !Dir.exist?(@archive.path!("versions/#{id}"))
      SnapshotArchive.identity!(id)
      write!(id) if @archive.current!(id)
    end
  end

  private

  # Return a portable bounded filename component, replacing unsafe characters;
  # a blank title becomes a neutral label. Input is a String, output is a String.
  def safe_title(title)
    cleaned = title.unicode_normalize(:nfkc).gsub(/[^\p{L}\p{N} .,_()'-]+/u, " ")
      .gsub(/\s+/u, " ").strip.gsub(/\A\.+|\.+\z/, "").strip
    cleaned = cleaned.byteslice(0, 120).scrub("").strip
    cleaned.empty? ? "Untitled Chat" : cleaned
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise SnapshotArchiveError, "usage: ruby named_exports.rb [data-repo]" if ARGV.length > 1
    root = File.expand_path(ARGV[0] || DEFAULT_DATA_REPO)
    binding_path = File.join(root, "versions", "binding.json")
    cursor = binding_path
    loop do
      raise SnapshotArchiveError, "symlink archive binding path refused" if File.symlink?(cursor)
      break if cursor == "/"
      cursor = File.dirname(cursor)
    end
    binding = SnapshotArchive.verify!(SnapshotArchive.parse(File.binread(binding_path)))
    archive = SnapshotArchive.new(root: root, project_id: binding.fetch("project_id"), account_id: binding.fetch("account_id"))
    paths = NamedExports.new(archive).backfill!
    puts "Verified named Markdown exports: #{paths.length} (#{File.join(root, 'named')})"
  rescue SnapshotArchiveError, JSON::ParserError, SystemCallError, KeyError => error
    warn "NAMED EXPORTS FAILED: #{error.message}"
    exit 1
  end
end
