# frozen_string_literal: true

require "securerandom"

class SnapshotArchiveError < StandardError; end

# Refuse duplicate JSON keys instead of losing source fields during parsing.
class SnapshotJSON < Hash
  # Assign a parsed object field; return its value or raise on duplicate names.
  def []=(key, value)
    raise SnapshotArchiveError, "duplicate JSON key: #{key}" if key?(key)
    super
  end
end

# Append complete conversation versions and capture observations in a single-writer
# local archive. Inputs are unedited local producer packages, not signed evidence.
# Operations raise SnapshotArchiveError or filesystem/JSON errors on unsafe paths,
# corrupt evidence or conflicts; historical files are never replaced.
class SnapshotArchive
  SCHEMA = "chat-snapshot/v1"
  OBSERVATION_SCHEMA = "chat-observation/v1"
  QUEUE_SCHEMA = "adventurefinder-chat-pending-queue/v0.2"
  CAPTURE_SCHEMA = "adventurefinder-chat-download-capture/v0.2"
  RENDERER = "active-branch/v1"
  RECOVERY_LIMIT = 10

  # Parse unambiguous JSON; return JSON-shaped values or raise parser/shape errors.
  # Reject nonfinite numbers and integers outside binary64's safe integer range.
  def self.parse(text)
    value = JSON.parse(text, object_class: SnapshotJSON)
    validate_numbers!(value)
    value
  end

  # Check numeric source evidence recursively without altering it; returns nil.
  def self.validate_numbers!(value)
    case value
    when Hash then value.each_value { |entry| validate_numbers!(entry) }
    when Array then value.each { |entry| validate_numbers!(entry) }
    when Numeric
      raise SnapshotArchiveError, "unsupported raw JSON number" unless value.finite? && (!value.is_a?(Integer) || value.abs <= 9_007_199_254_740_991)
    end
    nil
  end

  # Bind an existing archive to project/account strings; do not create any files.
  def initialize(root:, project_id:, account_id:)
    @root = File.expand_path(root)
    @project_id = project_id
    @account_id = account_id
    [project_id, account_id].each { |identity| self.class.identity!(identity) }
    path!("")
    raise SnapshotArchiveError, "archive must exist" unless Dir.exist?(@root)
    versions = path!("versions")
    if Dir.exist?(versions) && !File.exist?(path!("versions/binding.json")) &&
        Dir.children(versions).any? { |name| !name.start_with?(".") }
      raise SnapshotArchiveError, "archive binding missing from existing versions"
    end
    conflict!("versions/binding.json", JSON.pretty_generate(binding) + "\n")
  end

  # Return the sealed archive-wide binding; one archive belongs to one account/project.
  def binding
    self.class.seal({ "schema" => "chat-archive-binding/v1", "project_id" => @project_id, "account_id" => @account_id })
  end

  # Require a full safe identity, returning it or raising on traversal components.
  def self.identity!(value)
    raise SnapshotArchiveError, "unsafe or missing identity" unless value.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_-]{0,199}\z/.match?(value)
    value
  end

  # Sort object keys recursively; preserve arrays and every field/value. Used only
  # for structural digests, never to discard metadata or rewrite historical raw.
  def self.ordered(value)
    case value
    when Hash then value.keys.sort.to_h { |key| [key, ordered(value.fetch(key))] }
    when Array then value.map { |entry| ordered(entry) }
    else value
    end
  end

  # Hash ECT-01's typed encoding with sorted object keys and its binary64 numeric
  # contract. Returns SHA-256; serialization/key ordering is immaterial.
  def self.digest(value)
    Digest::SHA256.hexdigest(ReconcileHelpers.checkpoint_encoding(ordered(value)))
  end

  # Add an integrity checksum to JSON-shaped metadata; returns a new Hash.
  def self.seal(value)
    value.merge("sha256" => digest(value.reject { |key, _| key == "sha256" }))
  end

  # Verify metadata integrity; return the Hash or raise on missing/corrupt fields.
  def self.verify!(value)
    raise SnapshotArchiveError, "metadata checksum mismatch" unless value.is_a?(Hash) && value["sha256"] == seal(value)["sha256"]
    value
  end

  # Require canonical UTC milliseconds using ECT-01's normalizer. Returns input.
  def self.time!(value)
    raise SnapshotArchiveError, "invalid metadata timestamp" unless value.is_a?(String) && ReconcileHelpers.inventory_timestamp(value)[:value] == value
    value
  end

  # Validate a generated queue before ingestion. Returns it; legacy queues cannot
  # authorize binding/freshness. The checksum detects corruption, not re-signing.
  def self.queue!(queue)
    verify!(queue)
    raise SnapshotArchiveError, "trusted v0.2 queue required" unless queue["schema"] == QUEUE_SCHEMA && queue["pending"].is_a?(Array)
    %w[project_id account_id].each { |field| identity!(queue[field]) }
    source = queue["source"]
    raise SnapshotArchiveError, "missing inventory provenance" unless source.is_a?(Hash) &&
      source["schema"] == "adventurefinder-chat-project-inventory/v0.2" && source["producer"] == "project_inventory.js/ECT-01" &&
      %w[exhaustive incremental].include?(source["coverage"]) &&
      %w[checkpoint_sha256 inventory_sha256].all? { |field| /\A[0-9a-f]{64}\z/.match?(source[field].to_s) }
    %w[scan_started_at generated_at].each { |field| time!(source[field]) }
    raise SnapshotArchiveError, "inventory time order" if source["scan_started_at"] > source["generated_at"]
    audit = source["full_audit"]
    raise SnapshotArchiveError, "missing audit lineage" unless audit.is_a?(Hash)
    time!(audit["started_at"])
    raise SnapshotArchiveError, "invalid audit lineage" unless audit["id"] == audit["started_at"] && audit["id"] <= source["scan_started_at"]
    ids = queue["pending"].map do |entry|
      raise SnapshotArchiveError, "invalid queue entry" unless entry.is_a?(Hash) && entry["listing"].is_a?(Hash)
      identity!(entry["id"])
      listing = entry["listing"]
      raise SnapshotArchiveError, "listing identity mismatch" unless listing["id"] == entry["id"]
      time!(listing["last_observed_at"])
      raise SnapshotArchiveError, "future listing observation" if listing["last_observed_at"] > source["scan_started_at"]
      %w[create_time update_time].each do |field|
        status = listing["#{field}_status"]
        value = listing[field]
        raise SnapshotArchiveError, "invalid listing timestamp" unless %w[valid missing invalid].include?(status) &&
          (status == "valid" ? value && ReconcileHelpers.inventory_timestamp(value)[:value] == value : value.nil?)
      end
      entry["id"]
    end
    raise SnapshotArchiveError, "duplicate queue identities" unless ids.uniq == ids
    queue
  end

  # Return a contained path and reject every existing symlink component (including
  # the archive root). Single local writer required; hostile concurrent filesystem
  # mutation is outside this contract. Package paths never control destinations.
  def path!(relative)
    raise SnapshotArchiveError, "unsafe relative path" if relative.start_with?("/") || relative.split("/").include?("..")
    path = File.expand_path(relative, @root)
    raise SnapshotArchiveError, "path escaped archive" unless path == @root || path.start_with?(@root + "/")
    current = path
    loop do
      raise SnapshotArchiveError, "symlink path refused: #{current}" if File.symlink?(current)
      break if current == "/"
      current = File.dirname(current)
    end
    path
  end

  # Validate full raw identity and mapping, including non-active branches. Returns
  # raw; raises on malformed structures, dangling parents or cycles.
  def validate_raw!(raw, id)
    raise SnapshotArchiveError, "raw must be an object with embedded identity" unless raw.is_a?(Hash) && (raw.key?("id") || raw.key?("conversation_id"))
    %w[id conversation_id].each do |field|
      raise SnapshotArchiveError, "conflicting embedded conversation ID" if raw.key?(field) && raw[field] != id
    end
    { "project_id" => @project_id, "account_id" => @account_id }.each do |field, expected|
      raise SnapshotArchiveError, "conflicting embedded binding" if raw.key?(field) && raw[field] != expected
    end
    mapping = raw["mapping"]
    raise SnapshotArchiveError, "malformed mapping/current_node" unless mapping.is_a?(Hash) && !mapping.empty? && mapping.key?(raw["current_node"])
    mapping.each do |node_id, node|
      raise SnapshotArchiveError, "malformed mapping node" unless node.is_a?(Hash) && node["id"] == node_id &&
        (node["parent"].nil? || mapping.key?(node["parent"])) &&
        (node["children"].nil? || (node["children"].is_a?(Array) && node["children"].all? { |child| mapping.key?(child) })) &&
        (node["message"].nil? || (node["message"].is_a?(Hash) && node["message"]["author"].is_a?(Hash) && node["message"]["content"].is_a?(Hash)))
    end
    visited = {}
    mapping.each_key do |node_id|
      seen = {}
      current = node_id
      while current && !visited[current]
        raise SnapshotArchiveError, "mapping parent cycle" if seen[current]
        seen[current] = true
        current = mapping.fetch(current)["parent"]
      end
      seen.each_key { |seen_id| visited[seen_id] = true }
    end
    raw
  end

  # Read one complete bundle by digest. Verify metadata, raw content and both
  # file hashes; incomplete/tampered bundles fail instead of counting as complete.
  def version!(id, version)
    self.class.identity!(id)
    raise SnapshotArchiveError, "invalid version digest" unless /\A[0-9a-f]{64}\z/.match?(version.to_s)
    base = "versions/#{id}/#{version}"
    raise SnapshotArchiveError, "incomplete or unexpected bundle files" unless Dir.children(path!(base)).sort == %w[conversation.md raw.json version.json]
    metadata = self.class.verify!(self.class.parse(File.binread(path!("#{base}/version.json"))))
    raw_text = File.binread(path!("#{base}/raw.json"))
    markdown = File.binread(path!("#{base}/conversation.md"))
    raw = validate_raw!(self.class.parse(raw_text), id)
    unless metadata == self.class.seal({
      "schema" => SCHEMA, "project_id" => @project_id, "account_id" => @account_id,
      "conversation_id" => id, "version" => version, "renderer" => RENDERER,
      "raw_sha256" => Digest::SHA256.hexdigest(raw_text), "markdown_sha256" => Digest::SHA256.hexdigest(markdown)
    }) && version == self.class.digest(raw) && !markdown.empty?
      raise SnapshotArchiveError, "version identity/hash conflict"
    end
    metadata
  end

  # Return verified observations in deterministic capture order. Staged files are
  # never completion evidence; unreferenced bundles await download replay.
  def observations(id)
    self.class.identity!(id)
    directory = path!("versions/#{id}")
    return [] unless Dir.exist?(directory)
    Dir.children(directory).grep(/\A[0-9a-f]{64}\z/).each { |version| version!(id, version) }
    receipts = Dir.glob(path!("versions/#{id}/observations/*.json")).map do |path|
      receipt = self.class.verify!(self.class.parse(File.binread(path!(path.delete_prefix(@root + "/")))))
      raise SnapshotArchiveError, "observation binding mismatch" unless receipt["schema"] == OBSERVATION_SCHEMA &&
        receipt["project_id"] == @project_id && receipt["account_id"] == @account_id && receipt["conversation_id"] == id &&
        /\A[0-9a-f]{64}\z/.match?(receipt["package_sha256"].to_s) && File.basename(path) == "#{receipt["package_sha256"]}.json"
      %w[request_started_at captured_at].each { |field| self.class.time!(receipt[field]) }
      raise SnapshotArchiveError, "observation time order" if receipt["captured_at"] < receipt["request_started_at"]
      version!(id, receipt["version"])
      self.class.queue!(self.class.seal({ "schema" => QUEUE_SCHEMA, "project_id" => @project_id,
        "account_id" => @account_id, "source" => receipt["source"],
        "pending" => [{ "id" => id, "listing" => receipt["listing"] }] }))
      raise SnapshotArchiveError, "invalid observation provenance" unless
        %w[queue_sha256 raw_sha256 markdown_sha256].all? { |field| /\A[0-9a-f]{64}\z/.match?(receipt[field].to_s) } &&
        receipt["message_count"].is_a?(Integer) && receipt["message_count"].positive? &&
        receipt["source"]["generated_at"] <= receipt["request_started_at"] &&
        receipt["listing"]["last_observed_at"] <= receipt["request_started_at"]
      raw = self.class.parse(File.binread(path!("versions/#{id}/#{receipt["version"]}/raw.json")))
      fetched = ReconcileHelpers.inventory_timestamp(raw["update_time"])
      raise SnapshotArchiveError, "observation freshness conflict" unless receipt["fetched_update"] == fetched.transform_keys(&:to_s) &&
        receipt["freshness"] == freshness(receipt["listing"], fetched, receipt["request_started_at"])
      receipt
    end
    receipts.sort_by { |receipt| [receipt["request_started_at"], receipt["captured_at"], receipt["version"], receipt["package_sha256"]] }
  end

  # Return current only when its index matches the complete observation journal.
  # With repair, rebuild a missing/stale valid index after interruption. Corrupt or
  # invented indexes fail closed; no snapshot/source content is ever replaced.
  def current!(id, repair: false)
    receipts = observations(id)
    relative = "versions/#{id}/current.json"
    path = path!(relative)
    if File.exist?(path)
      index = self.class.verify!(self.class.parse(File.binread(path)))
      raise SnapshotArchiveError, "current index is not a verified observation" unless receipts.include?(index)
      return index if index == receipts.last
    end
    return nil if receipts.empty? || !repair
    atomic!(relative, JSON.pretty_generate(receipts.last) + "\n")
    receipts.last
  end

  # Return conservative freshness against the actual fetched timestamp. Agreement
  # is evidence as listed, never a claim of an atomic server snapshot.
  def freshness(listing, fetched, started)
    if listing.is_a?(Hash) && listing["update_time_status"] == "valid" && fetched[:status] == "valid" &&
        listing["update_time"] == fetched[:value] && fetched[:value] <= started && listing["last_observed_at"] <= started
      "verified-as-listed"
    else
      "unresolved"
    end
  end

  # Select new/updated IDs and at most ten unknown/retry captures. A disagreement
  # gets at most two attempts per observation. Missing dates use a bounded audit
  # lane, never daily history refetch. Returns [pending, per-ID evidence states].
  def select(records, legacy_ids)
    recovery_count = 0
    states = records.to_h do |record|
      id = self.class.identity!(record.fetch("id"))
      receipts = observations(id)
      latest = current!(id)
      verified = latest && latest["freshness"] == "verified-as-listed" &&
        record["update_time_status"] == "valid" && latest.dig("listing", "update_time") == record["update_time"]
      same_observation = receipts.select { |receipt| receipt["listing"] == record }
      reason = if verified
        "verified-unchanged"
      elsif latest.nil? && !receipts.empty?
        "incomplete"
      elsif latest.nil?
        legacy_ids.include?(id) ? "unknown-legacy" : "new"
      elsif record["update_time_status"] != "valid"
        latest.dig("listing", "last_full_audit_at") == record["last_full_audit_at"] ? "unknown-wait-audit" : "unknown-audit"
      elsif same_observation.length >= 2
        "unresolved-wait-inventory"
      else
        "updated"
      end
      candidate = %w[new updated incomplete unknown-legacy unknown-audit].include?(reason)
      recovery = reason.start_with?("unknown") || reason == "incomplete" || (latest && latest["freshness"] == "unresolved")
      if candidate && recovery
        recovery_count += 1
        candidate = false if recovery_count > RECOVERY_LIMIT
      end
      [id, { "id" => id, "state" => reason, "selected" => candidate, "current" => latest }]
    end
    pending = records.select { |record| states.fetch(record["id"])["selected"] }.map do |record|
      { "id" => record["id"], "title" => record["title"], "create_time" => record["create_time"],
        "update_time" => record["update_time"], "reason" => states.fetch(record["id"])["state"], "listing" => record }
    end
    [pending, states.values]
  end

  # Validate all preconditions/conflicts before archive writes. Install a bundle by
  # directory rename, then an immutable receipt, then a derived current index.
  # Exact replay repairs interruptions without duplicate versions. Returns the
  # latest verified observation. Optional fault hooks are for synthetic tests.
  def ingest(package_text, queue, fault: nil)
    self.class.queue!(queue)
    payload = self.class.parse(package_text)
    raise SnapshotArchiveError, "capture binding/schema mismatch" unless payload.is_a?(Hash) && payload["schema"] == CAPTURE_SCHEMA &&
      payload["project_id"] == @project_id && payload["account_id"] == @account_id &&
      queue["project_id"] == @project_id && queue["account_id"] == @account_id && payload["queue_sha256"] == queue["sha256"]
    id = self.class.identity!(payload["conversation_id"])
    entry = queue["pending"].find { |candidate| candidate["id"] == id }
    raise SnapshotArchiveError, "capture not in queue or listing mismatch" unless entry && payload["entry"] == entry
    %w[request_started_at captured_at].each { |field| self.class.time!(payload[field]) }
    raise SnapshotArchiveError, "capture time order" unless entry["listing"]["last_observed_at"] <= payload["request_started_at"] &&
      queue["source"]["generated_at"] <= payload["request_started_at"] && payload["request_started_at"] <= payload["captured_at"] &&
      payload["captured_at"] <= Time.now.utc.iso8601(3)
    raw_text = payload["raw_json"]
    markdown = payload["markdown"]
    raise SnapshotArchiveError, "malformed capture payload" unless raw_text.is_a?(String) && markdown.is_a?(String) && !markdown.empty? &&
      payload["message_count"].is_a?(Integer) && payload["message_count"].positive? && payload["renderer"] == RENDERER &&
      Digest::SHA256.hexdigest(raw_text) == payload["raw_sha256"] && Digest::SHA256.hexdigest(markdown) == payload["markdown_sha256"]
    raw = validate_raw!(self.class.parse(raw_text), id)
    version = self.class.digest(raw)
    metadata = self.class.seal({ "schema" => SCHEMA, "project_id" => @project_id, "account_id" => @account_id,
      "conversation_id" => id, "version" => version, "renderer" => RENDERER,
      "raw_sha256" => payload["raw_sha256"], "markdown_sha256" => payload["markdown_sha256"] })
    package_hash = Digest::SHA256.hexdigest(package_text)
    fetched = ReconcileHelpers.inventory_timestamp(raw["update_time"])
    receipt = self.class.seal({ "schema" => OBSERVATION_SCHEMA, "project_id" => @project_id, "account_id" => @account_id,
      "conversation_id" => id, "version" => version, "package_sha256" => package_hash,
      "source" => queue["source"], "queue_sha256" => queue["sha256"], "listing" => entry["listing"],
      "request_started_at" => payload["request_started_at"], "captured_at" => payload["captured_at"],
      "fetched_update" => fetched, "freshness" => freshness(entry["listing"], fetched, payload["request_started_at"]),
      "raw_sha256" => payload["raw_sha256"], "markdown_sha256" => payload["markdown_sha256"], "message_count" => payload["message_count"] })
    base = "versions/#{id}/#{version}"
    receipt_path = "versions/#{id}/observations/#{package_hash}.json"
    stage = "versions/.incoming/#{package_hash}"
    staged_files = { "raw" => ["raw.json", raw_text], "markdown" => ["conversation.md", markdown],
      "version" => ["version.json", JSON.pretty_generate(metadata) + "\n"] }
    [base, receipt_path, "versions/#{id}/current.json", "versions/.lock", stage].each { |relative| path!(relative) }
    ["versions", "versions/#{id}", "versions/#{id}/observations", "versions/.incoming", stage, base].each do |relative|
      path = path!(relative)
      raise SnapshotArchiveError, "expected directory: #{relative}" if File.exist?(path) && !Dir.exist?(path)
    end
    if Dir.exist?(path!(stage)) && (Dir.children(path!(stage)) - staged_files.values.map(&:first)).any?
      raise SnapshotArchiveError, "unexpected staged files; retain for inspection"
    end
    staged_files.each_value { |name, text| conflict!("#{stage}/#{name}", text) }
    current!(id)
    conflict!("versions/binding.json", JSON.pretty_generate(binding) + "\n")
    if Dir.exist?(path!(base))
      existing = version!(id, version)
      existing_raw = self.class.parse(File.binread(path!("#{base}/raw.json")))
      raise SnapshotArchiveError, "raw content-digest collision" unless existing_raw == raw
      raise SnapshotArchiveError, "same raw version has conflicting Markdown" unless existing["markdown_sha256"] == metadata["markdown_sha256"]
    end
    receipt_text = JSON.pretty_generate(receipt) + "\n"
    conflict!(receipt_path, receipt_text)
    FileUtils.mkdir_p(path!("versions"))
    File.open(path!("versions/.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      raise SnapshotArchiveError, "another archive writer is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      immutable!("versions/binding.json", JSON.pretty_generate(binding) + "\n")
      unless Dir.exist?(path!(base))
        FileUtils.mkdir_p(path!(stage))
        staged_files.each do |step, (name, text)|
          fault&.call("before_#{step}")
          immutable!("#{stage}/#{name}", text)
          fault&.call("after_#{step}")
        end
        FileUtils.mkdir_p(path!("versions/#{id}"))
        fault&.call("before_install")
        File.rename(path!(stage), path!(base))
        sync_directory(File.dirname(path!(base)))
        fault&.call("after_install")
      end
      version!(id, version)
      fault&.call("before_observation")
      immutable!(receipt_path, receipt_text)
      fault&.call("after_observation")
      current = observations(id).last
      fault&.call("before_index")
      atomic!("versions/#{id}/current.json", JSON.pretty_generate(current) + "\n")
      fault&.call("after_index")
      current
    end
  end

  # Reject different existing bytes before writes; missing files are accepted.
  def conflict!(relative, text)
    path = path!(relative)
    raise SnapshotArchiveError, "refusing different existing bytes: #{relative}" if File.exist?(path) && File.binread(path) != text
  end

  # Install an immutable file or accept identical existing bytes. Raises conflicts.
  def immutable!(relative, text)
    conflict!(relative, text)
    return if File.exist?(path!(relative))
    atomic!(relative, text)
  end

  # fsync a directory after rename; errors propagate rather than claiming durability.
  def sync_directory(path)
    File.open(path, File::RDONLY) { |directory| directory.fsync }
  end

  # Atomically replace a derived index or install new immutable content; fsync the
  # file and parent directory. Does not claim physical power-loss guarantees.
  def atomic!(relative, text)
    path = path!(relative)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp-#{SecureRandom.hex(8)}"
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(text); file.fsync }
    File.rename(temp, path)
    sync_directory(File.dirname(path))
  ensure
    File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
  end
end
