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

# A disposable cache of successful raw semantics, never archive evidence. Each
# operation loads a bounded, checksummed file and publishes only after success.
# Invalid/unavailable caches warn and fall back; unsafe/foreign files are retained.
class SnapshotValidationCache
  SCHEMA = "chat-raw-validation-cache/v1"
  MAX_BYTES = 16 * 1024 * 1024
  MAX_ENTRIES = 20_000

  # Bind derived entries to archive identities and all verifier/helper source.
  # Accept an explicit tooling-state path; cache I/O errors become diagnostics.
  def initialize(path:, binding:)
    @path, @binding = path, binding
    @entries = {}
    @writable = false
    sources = [__FILE__, File.join(__dir__, "reconcile_exports.rb")].map { |source| File.binread(source) }
    @policy = Digest::SHA256.hexdigest((sources + [RUBY_DESCRIPTION, JSON::VERSION]).join("\0"))
    load_entries
  rescue SystemCallError, IOError => error
    warn "Snapshot validation cache unavailable: #{error.message}; using full verification"
  end

  # Return normalized fetched time for these freshly hashed bytes, or validate
  # through the caller block on a miss. Exceptions propagate without publication.
  def fetch(id, version, raw_sha256)
    key = Digest::SHA256.hexdigest(JSON.generate([id, version, raw_sha256]))
    @entries[key] ||= yield.transform_keys(&:to_s)
    @entries.fetch(key).transform_keys(&:to_sym)
  end

  # Publish bounded derived results with exclusive temp creation and atomic
  # replacement. An interrupted write leaves the old cache usable; I/O warns.
  def publish
    return unless @writable

    safe_path!
    FileUtils.mkdir_p(File.dirname(@path))
    payload = { "schema" => SCHEMA, "binding" => @binding, "policy" => @policy,
      "entries" => @entries.to_a.last(MAX_ENTRIES).to_h }
    text = JSON.generate({ "payload" => payload, "sha256" => Digest::SHA256.hexdigest(JSON.generate(payload)) })
    return if text.bytesize > MAX_BYTES

    temp = "#{@path}.tmp-#{SecureRandom.hex(8)}"
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(text); file.fsync }
    File.rename(temp, @path)
    File.open(File.dirname(@path), File::RDONLY) { |directory| directory.fsync }
  rescue SystemCallError, IOError, SnapshotArchiveError => error
    warn "Snapshot validation cache unavailable: #{error.message}; full verification remains authoritative"
  ensure
    if defined?(temp) && temp && File.exist?(temp)
      begin
        File.delete(temp)
      rescue SystemCallError, IOError => error
        warn "Snapshot validation cache temporary file retained: #{error.message}"
      end
    end
  end

  private

  # Reject symlink components, nonregular files and hard links before cache I/O.
  # Returns nil; raises on unsafe paths, without following or replacing them.
  def safe_path!
    current = @path
    loop do
      raise SnapshotArchiveError, "unsafe cache symlink: #{current}" if File.symlink?(current)
      if File.exist?(current)
        stat = File.lstat(current)
        safe = current == @path ? stat.file? && stat.nlink == 1 : stat.directory?
        raise SnapshotArchiveError, "unsafe cache path: #{current}" unless safe
      end
      break if current == "/"
      current = File.dirname(current)
    end
    nil
  end

  # Load only strictly shaped, bounded, integrity-checked success data. A policy
  # change misses; malformed/foreign existing files are never overwritten.
  def load_entries
    safe_path!
    unless File.exist?(@path)
      @writable = true
      return
    end
    text = File.open(@path, "rb") { |file| file.read(MAX_BYTES + 1) }.to_s
    raise SnapshotArchiveError, "oversized cache" if text.bytesize > MAX_BYTES
    envelope = SnapshotArchive.parse(text)
    raise SnapshotArchiveError, "invalid cache envelope" unless envelope.is_a?(Hash) && envelope.keys.sort == %w[payload sha256]
    payload = envelope["payload"]
    raise SnapshotArchiveError, "cache checksum mismatch" unless envelope["sha256"] == Digest::SHA256.hexdigest(JSON.generate(payload))
    raise SnapshotArchiveError, "cache binding/shape mismatch" unless payload.is_a?(Hash) && payload.keys.sort == %w[binding entries policy schema] &&
      payload["schema"] == SCHEMA && payload["binding"] == @binding && /\A[0-9a-f]{64}\z/.match?(payload["policy"].to_s) &&
      payload["entries"].is_a?(Hash) && payload["entries"].length <= MAX_ENTRIES &&
      payload["entries"].all? { |key, value| /\A[0-9a-f]{64}\z/.match?(key) && valid_fetched?(value) }
    @writable = true
    @entries = payload["entries"] if payload["policy"] == @policy
  rescue SystemCallError, IOError, JSON::ParserError, SnapshotArchiveError => error
    warn "Snapshot validation cache ignored: #{error.message}; using full verification"
  end

  # Accept only the timestamp normalizer's exact successful output shape.
  # Returns Boolean; malformed cache data never becomes receipt freshness.
  def valid_fetched?(value)
    value.is_a?(Hash) && value.keys.sort == %w[status value] &&
      ((value["status"] == "valid" && value["value"].is_a?(String) &&
        ReconcileHelpers.inventory_timestamp(value["value"]) == value.transform_keys(&:to_sym)) ||
       (%w[missing invalid].include?(value["status"]) && value["value"].nil?))
  end
end

# Append complete conversation versions and capture observations in a single-writer
# local archive. Inputs are unedited local producer packages, not signed evidence.
# Operations raise SnapshotArchiveError or filesystem/JSON errors on unsafe paths,
# corrupt evidence or conflicts; historical files are never replaced.
class SnapshotArchive
  SCHEMA = "chat-snapshot/v1"
  LEGACY_OBSERVATION_SCHEMA = "chat-observation/v1"
  PREVIOUS_OBSERVATION_SCHEMA = "chat-observation/v2"
  OBSERVATION_SCHEMA = "chat-observation/v3"
  FRESHNESS_TOLERANCE_SECONDS = 3600
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
  def initialize(root:, project_id:, account_id:, validation_cache_path: nil)
    @root = File.expand_path(root)
    @validation_cache_path = validation_cache_path && File.expand_path(validation_cache_path)
    if @validation_cache_path && (@validation_cache_path == @root || @validation_cache_path.start_with?(@root + "/"))
      raise SnapshotArchiveError, "validation cache must be outside archive"
    end
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
    return verification_operation { version!(id, version) } unless @verification

    self.class.identity!(id)
    raise SnapshotArchiveError, "invalid version digest" unless /\A[0-9a-f]{64}\z/.match?(version.to_s)
    return @verification.fetch([id, version]).first if @verification.key?([id, version])

    base = "versions/#{id}/#{version}"
    raise SnapshotArchiveError, "incomplete or unexpected bundle files" unless Dir.children(path!(base)).sort == %w[conversation.md raw.json version.json]
    metadata = self.class.verify!(self.class.parse(File.binread(path!("#{base}/version.json"))))
    raw_text = File.binread(path!("#{base}/raw.json"))
    markdown = File.binread(path!("#{base}/conversation.md"))
    raw_sha256 = Digest::SHA256.hexdigest(raw_text)
    fetched = if @validation_cache
      @validation_cache.fetch(id, version, raw_sha256) { raw_semantics!(raw_text, id, version) }
    else
      raw_semantics!(raw_text, id, version)
    end
    unless metadata == self.class.seal({
      "schema" => SCHEMA, "project_id" => @project_id, "account_id" => @account_id,
      "conversation_id" => id, "version" => version, "renderer" => RENDERER,
      "raw_sha256" => raw_sha256, "markdown_sha256" => Digest::SHA256.hexdigest(markdown)
    }) && !markdown.empty?
      raise SnapshotArchiveError, "version identity/hash conflict"
    end
    @verification[[id, version]] = [metadata, fetched]
    metadata
  end

  # Fully validate exact raw bytes against identity, graph and structural version;
  # return normalized fetched time. Parser/semantic errors propagate on misses.
  def raw_semantics!(raw_text, id, version)
    raw = validate_raw!(self.class.parse(raw_text), id)
    raise SnapshotArchiveError, "version identity/hash conflict" unless version == self.class.digest(raw)
    ReconcileHelpers.inventory_timestamp(raw["update_time"])
  end

  # Share only complete bundles within one public lookup/selection operation.
  # Always recheck archive binding; later calls re-enumerate and rehash everything.
  # Persist successes only after the whole operation returns; errors propagate.
  def verification_operation
    @verification = {}
    versions = path!("versions")
    if Dir.exist?(versions) && !File.exist?(path!("versions/binding.json")) &&
        Dir.children(versions).any? { |name| !name.start_with?(".") }
      raise SnapshotArchiveError, "archive binding missing from existing versions"
    end
    conflict!("versions/binding.json", JSON.pretty_generate(binding) + "\n")
    @validation_cache = SnapshotValidationCache.new(path: @validation_cache_path, binding: binding) if @validation_cache_path
    result = yield
    @validation_cache&.publish
    result
  ensure
    @verification = @validation_cache = nil
  end

  # Return verified observations in deterministic capture order. Staged files are
  # never completion evidence; unreferenced bundles await download replay.
  def observations(id)
    return verification_operation { observations(id) } unless @verification

    self.class.identity!(id)
    directory = path!("versions/#{id}")
    return [] unless Dir.exist?(directory)
    Dir.children(directory).grep(/\A[0-9a-f]{64}\z/).each { |version| version!(id, version) }
    receipts = Dir.glob(path!("versions/#{id}/observations/*.json")).map do |path|
      receipt = self.class.verify!(self.class.parse(File.binread(path!(path.delete_prefix(@root + "/")))))
      raise SnapshotArchiveError, "observation binding mismatch" unless [LEGACY_OBSERVATION_SCHEMA, PREVIOUS_OBSERVATION_SCHEMA, OBSERVATION_SCHEMA].include?(receipt["schema"]) &&
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
      fetched = @verification.fetch([id, receipt["version"]]).last
      raise SnapshotArchiveError, "observation freshness conflict" unless receipt["fetched_update"] == fetched.transform_keys(&:to_s) &&
        receipt["freshness"] == freshness(receipt["listing"], fetched, receipt["request_started_at"], schema: receipt["schema"])
      receipt
    end
    receipts.sort_by { |receipt| [receipt["request_started_at"], receipt["captured_at"], receipt["version"], receipt["package_sha256"]] }
  end

  # Return current only when its index matches the complete observation journal.
  # With repair, rebuild a missing/stale valid index after interruption. Corrupt or
  # invented indexes fail closed; no snapshot/source content is ever replaced.
  def current!(id, repair: false)
    return verification_operation { current!(id, repair: repair) } unless @verification

    receipts = observations(id)
    current_from_observations!(id, receipts, repair: repair)
  end

  # Verify a live index against this operation's fully checked journal; optionally
  # repair a missing/stale valid index. Returns receipt/nil; corrupt indexes raise.
  def current_from_observations!(id, receipts, repair: false)
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
  private :current_from_observations!

  # Compare validated listing/fetched timestamps without rounding or changing them.
  # Historical v1/v2 receipts retain equality/one-second policies; new v3
  # receipts accept an inclusive one-hour difference.
  # Neither source time may exceed request start. Returns a freshness String;
  # raises SnapshotArchiveError for unknown policies; timestamp parsing errors propagate.
  def freshness(listing, fetched, started, schema: OBSERVATION_SCHEMA)
    tolerance = case schema
    when LEGACY_OBSERVATION_SCHEMA then 0
    when PREVIOUS_OBSERVATION_SCHEMA then 1
    when OBSERVATION_SCHEMA then FRESHNESS_TOLERANCE_SECONDS
    else raise SnapshotArchiveError, "unsupported observation freshness policy"
    end
    if listing.is_a?(Hash) && listing["update_time_status"] == "valid" && fetched[:status] == "valid" &&
        listing["update_time"] <= started && fetched[:value] <= started && listing["last_observed_at"] <= started &&
        (Time.iso8601(listing["update_time"]).to_r - Time.iso8601(fetched[:value]).to_r).abs <= tolerance
      "verified-as-listed"
    else
      "unresolved"
    end
  end

  # Reassess an already validated receipt under today's tolerance without rewriting
  # its historical schema, timestamps or freshness. Returns a freshness String;
  # required-field/parse errors propagate for malformed caller input.
  def capture_freshness(receipt)
    freshness(receipt.fetch("listing"), receipt.fetch("fetched_update").transform_keys(&:to_sym),
      receipt.fetch("request_started_at"))
  end

  # Return the content-relevant listing fields for inspection completion. Scan/audit
  # provenance is retained in receipts but must not make unchanged content new.
  # Accept a validated listing Hash and return its stable revision fields.
  def listing_revision(listing)
    listing.slice("id", "title", "create_time", "create_time_status", "update_time", "update_time_status")
  end

  # Return whether a validated complete capture inspected this exact listing
  # revision, independent of timestamp agreement. Accept nil current evidence;
  # callers must use current! first so corrupt/incomplete bundles fail closed.
  def captured_unchanged?(current, listing)
    current && listing_revision(current.fetch("listing")) == listing_revision(listing)
  end

  # Select new/changed listings and at most ten uncaptured historical IDs.
  # Successful captures satisfy their exact listing revision, even with unresolved
  # timestamps. Scan/audit provenance alone cannot queue them again.
  # An optional block receives no arguments after each checked record, for progress.
  # Returns [pending, per-ID evidence states]; corrupt archive evidence raises.
  def select(records, legacy_ids)
    return verification_operation { select(records, legacy_ids) { yield if block_given? } } unless @verification

    recovery_count = 0
    states = records.to_h do |record|
      id = self.class.identity!(record.fetch("id"))
      receipts = observations(id)
      latest = current_from_observations!(id, receipts)
      evaluated_freshness = latest && capture_freshness(latest)
      captured = !!captured_unchanged?(latest, record)
      reason = if captured
        evaluated_freshness == "verified-as-listed" ? "verified-unchanged" : "captured-unchanged"
      elsif latest.nil? && !receipts.empty?
        "incomplete"
      elsif latest.nil?
        legacy_ids.include?(id) ? "unknown-legacy" : "new"
      else
        "updated"
      end
      candidate = %w[new updated incomplete unknown-legacy].include?(reason)
      recovery = reason == "unknown-legacy" || reason == "incomplete"
      if candidate && recovery
        recovery_count += 1
        candidate = false if recovery_count > RECOVERY_LIMIT
      end
      yield if block_given?
      [id, { "id" => id, "state" => reason, "selected" => candidate, "recovery" => recovery,
        "captured_for_listing" => captured, "freshness" => evaluated_freshness, "current" => latest }]
    end
    pending = records.select { |record| states.fetch(record["id"])["selected"] }
      .sort do |left, right|
        left_recovery = states.fetch(left["id"])["recovery"] ? 1 : 0
        right_recovery = states.fetch(right["id"])["recovery"] ? 1 : 0
        comparison = left_recovery <=> right_recovery
        comparison = right["update_time"].to_s <=> left["update_time"].to_s if comparison.zero?
        comparison = left["id"] <=> right["id"] if comparison.zero?
        comparison
      end.map do |record|
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
    receipt_path = "versions/#{id}/observations/#{package_hash}.json"
    # Exact historical package replay must reproduce the original receipt bytes.
    # Its schema is checked here and by current! before any archive writes.
    receipt_schema = if File.exist?(path!(receipt_path))
      self.class.verify!(self.class.parse(File.binread(path!(receipt_path)))).fetch("schema")
    else
      OBSERVATION_SCHEMA
    end
    fetched = ReconcileHelpers.inventory_timestamp(raw["update_time"])
    receipt = self.class.seal({ "schema" => receipt_schema, "project_id" => @project_id, "account_id" => @account_id,
      "conversation_id" => id, "version" => version, "package_sha256" => package_hash,
      "source" => queue["source"], "queue_sha256" => queue["sha256"], "listing" => entry["listing"],
      "request_started_at" => payload["request_started_at"], "captured_at" => payload["captured_at"],
      "fetched_update" => fetched, "freshness" => freshness(entry["listing"], fetched, payload["request_started_at"], schema: receipt_schema),
      "raw_sha256" => payload["raw_sha256"], "markdown_sha256" => payload["markdown_sha256"], "message_count" => payload["message_count"] })
    base = "versions/#{id}/#{version}"
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
