# ChatGPT project resumable batch export

This layer keeps the existing single-chat scripts intact. It uses the project inventory stored in the sibling `export-chats-data` repository, conservatively reconciles existing Markdown exports to conversation IDs, and prepares a browser-console runner for only the remaining conversations.

ChatGPT's page Content-Security-Policy blocks page JavaScript from connecting to `127.0.0.1`, so the batch runner deliberately does **not** use a localhost HTTP bridge. Instead, each successful conversation fetch creates one `AFCHAT_*.json` download package containing the raw conversation plus rendered Markdown. A local Ruby watcher ingests those completed downloads into `export-chats-data` atomically.

New captures are written as:

- `versions/<full-id>/<content-digest>/raw.json` — authoritative source response;
- `versions/<full-id>/<content-digest>/conversation.md` — derived active-branch Markdown;
- checked version metadata, immutable observations and a derived current index.

Earlier raw and Markdown files stay byte-for-byte unchanged at their original paths.

Runtime/checkpoint files live under `export-chats-tooling/.state/` and are ignored by Git.

## 0. Inventory your project

Open the ChatGPT Project you want to archive, copy `project_inventory.js`, and
paste it into that page's developer console. On macOS, from this checkout:

```bash
pbcopy < project_inventory.js
```

The script uses the project ID from the open URL and selected account ID from
the authenticated browser session. Empty and large projects are supported.
The first run exhausts cursors from "0". Listing stays sequential, with one
second between requests, no retries, and a 10,000-page hard limit. Non-OK
responses, including HTTP 429, stop without a new result; wait before retrying.

Successful downloads keep the existing YYYY-MM-DD - ChatGPT <project-id>
Project Inventory.json/.csv names. Long IDs are shortened only in filenames.
Retain previous JSONs under distinct names before saving new results; same-day
download names alone do not distinguish runs. JSON is the checkpoint and
reconciliation input. CSV remains an inspection export, including cumulative
rows and timestamp/observation status; it has no trusted checkpoint metadata.

### Daily discovery and explicit audits

After saving the first JSON, run reconciliation (section 1). It generates
.state/project_inventory_console.js, embedding that exact saved checkpoint.
Copy this generated script for the next daily run and paste it into the same
project's console:

~~~bash
pbcopy < .state/project_inventory_console.js
~~~

After success, save the new JSON and rerun reconciliation to regenerate the
next script. On an uninterrupted browser page, rerunning the bare source also
uses the last successful window.__chatProjectInventoryPrevious. Output remains
available as window.__chatProjectInventory and the compatibility alias
window.__adventureFinderProjectInventory.

Force an exhaustive audit before running either script:

~~~javascript
window.__chatProjectInventoryFullAudit = true;
~~~

Clear the persistent option afterward:

~~~javascript
delete window.__chatProjectInventoryFullAudit;
~~~

An audit is automatic when the latest successful full audit is at least seven
days old. Seven days is also the maximum baseline age allowed for a partial
result. Initial/missing checkpoints and baselines with unusable update times or
observed ordering anomalies use exhaustive pagination.

Malformed, corrupt, unsupported, project/account-mismatched or future-dated
checkpoints are refused before listing, never silently reset. Restore the last
valid matching JSON, regenerate the console script and force an audit. A failed
run does not replace the prior checkpoint or trigger downloads.

An optional count assertion also forces a full audit:

~~~javascript
window.__chatProjectInventoryExpectedCount = 500; // actual expected listing
~~~

Only non-negative safe integers, including zero, are accepted. The assertion
compares freshly observed IDs after exhaustion, never the cumulative total.
A mismatch refuses publication. Clear the persistent setting for daily use:

~~~javascript
delete window.__chatProjectInventoryExpectedCount;
~~~

A matched count does not prove server completeness or archived content.

### Inventory contract for downstream consumers (ECT-02)

This section defines the binding v0.2 inventory/timestamp contract. Legacy v0.1
JSON remains readable for historical reconciliation. ECT-02 consumes this contract
for update selection and versioned capture below; it does not change pagination.

- **schema** is adventurefinder-chat-project-inventory/v0.2; **producer** is
  project_inventory.js/ECT-01. **project_id** and non-secret **account_id** bind
  all records and baseline lineage to the browser selection. Tokens, session
  objects and credentials are never stored in manifests or logs.
- **conversations** is the cumulative known-ID set, including records absent
  from the current listing. Fresh observations replace metadata for that ID;
  absence never deletes an ID or establishes deletion/movement.
  **known_conversation_count** counts this set.
- Rows have **id**, nullable **title**, **create_time**, **update_time**, their
  status fields, **observed_in_scan**, **last_observed_at**, and nullable
  **last_full_audit_at**. A false observation flag means retained historical
  evidence. Comparing last_full_audit_at with full_audit.id identifies IDs seen
  in that audit.
- **raw_pages** contains only the current scan's original listing pages.
  **observed_conversation_count** counts their unique IDs; **page_count** counts
  listing requests. They may be a small subset of conversations.
  Reconciliation must use the cumulative v0.2 records even when raw pages exist.
- **coverage: "exhaustive"** means the current scan reached a null/absent cursor.
  It describes this scan, not every historical row. **"incremental"** means an
  overlapping prefix stopped with a validated continuation.
  **scan_reason** distinguishes initial/daily/forced/due/count-audit/fallback.
- **scan_started_at** is local UTC scan start; **generated_at** is construction
  time. **watermark** equals scan start, not the newest row timestamp, capture
  time, or proof all prior changes were observed.
- **full_audit** records the latest exhausted scan's ID (its UTC start),
  **started_at**, observed count, page count, and whether every update time was
  usable and nonincreasing. Partial scans carry it unchanged. Exhaustion creates
  a new baseline while retaining historical IDs. An unordered full audit is
  valid exhaustive evidence but cannot authorize future early stopping.
- **overlap_ms** and **audit_interval_ms** are both 604800000 (seven days).
  The daily **cutoff** is previous.watermark minus overlap_ms. Every fetched row
  and ordering within/across pages is validated; stopping requires the page's
  final update time to be strictly older than cutoff. All cutoff ties are
  included. A successful partial scan uses fewer than 100 pages.
- Missing/invalid update evidence, observed disorder or reaching 100 daily pages
  switches the same validated traversal to exhaustion, labeled exhaustive on
  success. Malformed pages, duplicate IDs, invalid/cyclic cursors, empty
  nonterminal pages, HTTP failures or the hard page limit refuse publication.
  Merging never hides these errors.
- **checkpoint_sha256** covers everything except that field. The browser and
  reconciler hash UTF-8 of a typed encoding: null=n; boolean=b0/b1; string=s plus
  JSON string encoding; number=d plus 16 lowercase hex digits of big-endian
  IEEE-754 binary64 (negative zero normalized to zero); array=[ plus
  comma-joined encodings plus ]; object={ plus comma-joined JSON-key/colon/value
  encodings in insertion order plus }. Undefined object fields are omitted;
  undefined array entries/nonfinite values encode as null like JSON serialization.
  The digest binds identity, schema, lineage, cumulative records and scan proof
  against accidental corruption. It is not a signature or protection against
  deliberate re-signing. Trust only unedited, locally generated checkpoints.

Legacy v0.1 files lack account/provenance evidence and cannot authorize early
stopping or automatic cumulative transfer into a v0.2 checkpoint. Supplying one
as the previous checkpoint is refused. Retain legacy files for reconciliation,
independently establish a new exhaustive v0.2 baseline, and review historical
IDs absent from the endpoint rather than silently assigning them to an account.
Legacy numeric records and ISO strings in raw pages remain consumable; legacy
raw pages remain preferred over formerly lossy normalized rows. Duplicate IDs
are rejected rather than deduplicated. Legacy input is labeled
legacy-unverified, never promoted to a trusted baseline.

### Timestamp forms and discovery guarantees

Supported numeric values are finite **Unix epoch seconds**, including fractions,
rounded to milliseconds (half-millisecond ties toward positive infinity).
Milliseconds/microseconds are not auto-detected. Supported ISO forms are
YYYY-MM-DDTHH:mm:ss[.S|.SS|.SSS]Z or the same with numeric ±HH:mm offsets through
±14:00. Dates use the proleptic Gregorian calendar, years 0001–9999; resulting
UTC instants must also be in that range. Calendar dates, hours, minutes, seconds
and offsets must be valid. Unzoned strings, leap seconds, unknown -00:00 offsets,
more than three fractional digits, numeric strings, NaN/infinity and
out-of-range values are invalid.

Valid values become YYYY-MM-DDTHH:mm:ss.sssZ consistently in JSON, CSV and
reconciliation. Null, absent and empty strings are **missing**; other unusable
values are **invalid**. Both yield null normalized times, with distinct
**create_time_status**/**update_time_status** fields. Current raw pages retain
original JSON values. Missing/invalid dates never become today or authorize a
watermark. JSON cannot represent NaN/infinity: synthetic non-JSON evidence may
be refused on reuse instead of becoming trusted. Legacy times normalize to the
same UTC representation; invalid dates cannot resolve ambiguous title matches.

**Conditional daily guarantee:** if a record is visible during scanning and
the entire listing, including its unseen suffix, is nonincreasing by update
time, every new chat, recently updated old chat or delayed addition timestamped
at/after cutoff is fetched. A locally ordered prefix cannot prove unseen suffix
ordering. Old creation dates do not prevent discovery of recent updates.

Just-beyond-cutoff and backdated additions may wait for a full audit; extra
crossing-page rows are incidental, not a wider guarantee. With successful daily
runs and visible, consistently paginated records, forced audits recover
immediately; automatic audits recover within seven days plus at most one daily
scheduling interval (at most eight days). Missed/failed runs extend the bound.
Persistent endpoint omissions or changes during pagination provide no finite
completeness guarantee.

Seven-day defaults are operational choices demonstrated by fixtures, not live
API promises. A 500-chat, 10-item-page fixture needs 50 full listing requests;
sparse additions, a recently updated old chat and a delayed addition inside
overlap take two daily requests, exceeding the predeclared 80% reduction target.
Ties, a one-millisecond-beyond boundary, backdated additions and unseen suffix
disorder demonstrate the need for audits. Dense recent histories may require
exhaustive scans.

Cursor exhaustion verifies only the listing returned by an undocumented
endpoint, not account-wide completeness or an atomic snapshot. Avoid moving,
adding or deleting chats during scans. Pending/completed counts cover known IDs
and existing capture evidence; zero pending does not mean unseen chats or
changes to already archived content were captured. ECT-02 must not interpret
inventory timestamps as content versions or archival freshness.

### Daily update selection and unknown freshness

New captures require a validated ECT-01 v0.2 inventory with project/account binding.
Legacy inventory files remain readable for historical matching, but cannot authorize
capture: first establish an exhaustive v0.2 baseline. Reconciliation generates a
checksummed v0.2 queue with the inventory checksum, exact inventory-file SHA-256,
scan/audit provenance and each selected cumulative listing record.

`reconciliation.json` separates `legacy_evidence` from verified `completed` and
per-ID `freshness` states. `archived_conversation_count` counts verified complete
snapshot bundles regardless of timestamp agreement; `archived_unresolved_count`
counts the subset unresolved under the current tolerance. These are distinct from freshness
completion. `unresolved_markdown_payloads` concerns legacy root-file matching
(including Codex sessions), not the number of conversations missing content.
An old creation date does not suppress a recent update.
`new` identifies IDs without historical matching or a verified snapshot. `updated`
means the latest listing differs from captured evidence or freshness is unresolved.
`verified-unchanged` skips capture when a checked capture's valid listing and fetched
update times differ by at most **one second, inclusive**, in either direction, and
the current listing update time still matches the captured listing **exactly**.
Neither update timestamp may be later than request start. Tolerance is applied
only to freshness agreement, using exact rational seconds without rounding;
inventories, watermarks, revision keys, source timestamps and content digests
are unchanged. Timestamp normalization is unchanged. A one-millisecond listing
change still requests inspection.
This assumes the provider changes update time when content changes; equal-time
provider changes cannot be discovered from timestamps alone.

Legacy Markdown matches, raw-only files and old `.state` completion entries have
**unknown freshness**, irrespective of filename, date or modification time. They
are never promoted into version metadata or assigned invented capture dates.
At most **ten** unknown/bootstrap/recovery IDs are selected per reconciliation,
in full-ID lexical order. Further IDs remain explicitly deferred; rerun after
draining the selected queue to progress through a large legacy archive. This is
an operator-driven bootstrap, not a daily full-history capture. Genuinely new IDs
and first inspections of changed listings do not use this ten-ID budget, including
when the previous capture was unresolved. They precede recovery entries in the
browser queue, with newest updates first within each lane.

A valid but disagreeing listing/fetch pair gets at most **two distinct captured
attempts per stable listing revision**: identity, title, creation/update values
and their statuses. Exact download replay consumes no extra attempt. Scan flags,
observation times and audit lineage remain in immutable receipts but do not reset
this limit. Afterward it remains `unresolved-wait-inventory`; changed listing
fields allow a new inspection. Missing/invalid source update times remain
unresolved and use `unknown-wait-audit` after a capture, with at most ten selected
on a later full audit (`unknown-audit`). There is no per-day refetch of every old
chat. Zero pending may coexist with unknown/deferred IDs: inspect the report.
An absent ID in a partial listing never removes any archived file or observation.

Listing and conversation endpoints can report different update times. ISO input
currently truncates sub-millisecond digits while numeric seconds round them, so
even the same source instant can differ by one millisecond. New `chat-observation/v2`
receipts record freshness using the one-second tolerance. Existing
`chat-observation/v1` receipts continue to validate under their original exact
comparison, including exact package replay. Mixed journals are supported; unknown
schemas and falsified historical freshness fail closed. Tools predating v2 cannot
read new v2 receipts; retain the upgraded tooling when using those captures.

Reconciliation and watcher completion also reassess checked historical receipts
under the current tolerance without rewriting their bytes, checksum, original
freshness or `current.json`. No recapture is needed for a qualifying v1 receipt.
The report's per-ID `freshness` contains this current evaluation; nested `current`
is the original receipt and may still say `unresolved`. The report/checkpoint's
`freshness_tolerance_seconds` records the current rule. Missing/invalid timestamp
evidence and differences greater than one second remain unresolved; raw-only
legacy files are not promoted. The tolerance is a practical agreement policy,
not proof of an atomic server snapshot or identical content within that interval.
The bounded retry policy still prevents unlimited recapture of unchanged listings.

### Version storage, digest and current lookup

ECT-02 leaves every existing `raw/<id>.json` and root Markdown file in place and
byte-for-byte unchanged. New authoritative captures are additive:

```text
versions/binding.json                         # one project/account per archive
versions/<full-id>/<version>/raw.json          # exact first response UTF-8 JSON
versions/<full-id>/<version>/conversation.md   # derived active-branch reading
versions/<full-id>/<version>/version.json      # identity, renderer, file hashes
versions/<full-id>/observations/<package-sha256>.json
versions/<full-id>/current.json                # derived, verified observation
```

`version` is SHA-256 of the **entire parsed raw JSON**, using ECT-01's typed
encoding with recursively sorted object keys. Arrays retain order, numbers use
binary64 semantics, and no volatile metadata fields are excluded. Source fields,
inactive branches, mapping and provider metadata survive. Duplicate object keys,
nonfinite numbers and integers outside ±(2^53−1) are rejected to avoid ambiguous
equality. Whitespace, object-key ordering and equivalent numeric serialization
do not create versions; the first raw response's exact bytes remain authoritative.
Every bundle additionally hashes its exact raw/Markdown bytes. Same raw content
with different Markdown under `active-branch/v1` is a conflict, not an overwrite.

A changed provider metadata field creates a version even if readable messages
stay the same. An advanced **listing** time with identical fetched raw creates no
duplicate bundle: a separate immutable observation records the attempt, listing,
inventory hashes/provenance, request/capture times, fetched update value/status,
raw/Markdown hashes and freshness. Serialization-only repeats record the newly
observed wire hash; they retain the first raw serialization rather than another
raw copy. Metadata checksums detect corruption, not malicious re-signing. Only
unedited local inventory/queue/browser packages are trusted producer evidence.

Canonical/current means the last complete **capture observation**, ordered by
`request_started_at`, then `captured_at`, then full version digest, then package
SHA-256 (all ascending). Source update times do not order versions: they can be
equal, move backwards or disagree. An out-of-order download cannot rewind current;
a later capture of restored old content points back to its existing bundle.
Local clock accuracy is required for capture ordering; no server revision ID or
atomic server snapshot is claimed. A current bundle may have unresolved freshness.

For verified lookup, use the Ruby API after replacing example paths/identities:

```ruby
require_relative "reconcile_exports"
archive = SnapshotArchive.new(root: "/path/to/archive",
  project_id: "g-p-example", account_id: "account-example")
current = archive.current!("full-conversation-id")
history = archive.observations("full-conversation-id")
metadata = archive.version!("full-conversation-id", "64-character-version-digest")
```

`current!` returns nil for an interrupted missing/stale index and raises for
corruption; `version!` verifies all three bundle files and raises on missing or
different bytes. To restore an older reading **without changing history**, verify
its version, create a fresh destination directory with `Dir.mkdir` (fails if it
already exists), then copy that bundle's three files there. Do not overwrite
legacy paths or edit `current.json`. Copying an older reading does not change
archival freshness or restore messages into ChatGPT; a subsequent real capture
records any provider-side restoration as a new observation.

### Capture races and interruption recovery

The browser binds its current selected account to the queue before fetching,
validates full embedded IDs, renders conservatively and downloads exact raw bytes
with SHA-256 hashes. The watcher validates queue/capture schema, binding, IDs,
hashes, timestamps and full mapping before archive writes. Invalid metadata times
are rejected; missing/invalid **source** times are retained as unresolved evidence.
Conflicting IDs, duplicate keys, malformed mappings, cycles, path traversal and
existing symlink components are refused. Packages do not supply destination paths.
One local writer per tooling/archive pair is required; hostile concurrent filesystem
mutation is outside the path checks' guarantee.

`verified-as-listed` requires valid equal listing/fetched update times, no source
update later than request start, and listing observation before request start.
Other captures retain exactly what was fetched with `unresolved` freshness.
An update racing ahead of the listing, a lagging fetch, or contradictory timestamps
cannot advance freshness. Equal timestamps cannot prove no update happened after
the response or that the provider exposed a consistent snapshot; later inventory
and ECT-01 audits remain necessary. No atomic server or power-loss claim is made.

Ingestion stages raw, Markdown and version metadata under `versions/.incoming/`,
fsyncs individual writes and renames the complete directory into place. Only then
does it install the immutable observation, derived current index and local
`.state/capture_status.json` checkpoint. Files and rename parents are fsynced;
physical media/controller durability across power failure has not been measured.
The checkpoint is a derived cache: raw-only files, download clicks and stale old
status entries cannot establish completion. `ingested` means a complete verified
bundle/index; `completed` additionally requires agreement with the queued listing.

Keep rejected/incomplete downloads and the matching queue/script. Stop the browser,
restart the watcher with that queue, and replay the retained download: identical
staged writes are accepted, missing steps repaired, and no duplicate bundle or
observation is created. Complete observations repair missing/stale valid indexes
and checkpoints on watcher restart. Missing/altered immutable bundle or observation
metadata, invented indexes, and different existing staged bytes fail closed;
inspect the reported paths and recover original evidence rather than editing
hashes or deleting historical versions. Do not regenerate away the matching queue
before draining downloads; queue mismatch is rejected with the download retained.
Partial/unreferenced bundles do not count as complete. Unreferenced staging files
can be retained for investigation; the watcher does not silently delete them.

## 1. Reconcile the existing archive

From your `export-chats-tooling` checkout:

```bash
ruby reconcile_exports.rb
```

The default archive is the sibling `../export-chats-data` directory. Discovery
selects the most recently modified `*Project Inventory.json` in that archive,
including older `AdventureFinder Project Inventory.json` files. An explicit data
path and inventory path may also be supplied as the first and second arguments:

```bash
ruby reconcile_exports.rb /path/to/archive "/path/to/archive/YYYY-MM-DD - ChatGPT <project-id> Project Inventory.json"
```

Use one archive per project. If inventories for several projects share a
directory, always supply the exact JSON path; default discovery does not select
a project for you. The existing `.state/` checkpoints support one project at a
time, so use separate tooling checkouts when archiving several projects.

Review `.state/reconciliation.json`. Historical matching uses unique normalized
titles or creation dates for duplicate titles, and records its evidence separately.
Such matches remain unknown until bootstrapped; only verified version observations
can skip capture on freshness grounds.

Reconciliation also generates .state/project_inventory_console.js for the next
discovery run and .state/project_batch_console.js, which embeds the exact pending queue into the checked-in browser runner. This avoids all cross-origin localhost requests.

## 2. Start the download watcher

```bash
ruby capture_watch.rb
```

By default it watches `~/Downloads` for completed `AFCHAT_*.json` files. Set `CHAT_EXPORT_DOWNLOAD_DIR` or pass a second positional path if Firefox saves elsewhere.

After startup validation, a normal watcher whose initial reconciled pending queue
is empty reports completion and exits successfully without scanning Downloads or
sleeping. Queue entries, not watcher completion totals, determine this condition.
An initially nonempty watcher continues polling after successful captures. Rerun
reconciliation and restart the watcher to load a newly generated queue.
`--once` intentionally still makes two scans with a short stabilization sleep,
even with an empty queue, and can diagnose leftover downloads.

Rejected files stay in Downloads. Each unchanged file/error is diagnosed once
per watcher process; different errors remain visible, and restarting can report
the rejection again. Stabilization and warning suppression compare device,
inode, mode, size, and full-resolution modification/change times. This detects
normal same-size edits and replacements, including replacements preserving mtime;
it does not detect deliberately forged filesystem metadata. Disappeared paths
are forgotten. Changed files must stabilize and pass full validation again;
unchanged retries also retain normal validation and overwrite checks. Existing
status must be readable JSON with compatible project/account binding when present.
Legacy unbound status is rebuilt too; its old completion entries never authorize
captures.

For every valid package the watcher:

1. verifies project/account, inventory, full conversation identity and hashes;
2. installs a complete raw/Markdown/metadata version and capture observation;
3. verifies current lookup and updates `.state/capture_status.json`;
4. deletes the temporary download package only after successful ingestion.

Stopping it with `Ctrl-C` is safe.

## 3. Smoke-test two conversations

Copy the generated console program:

```bash
pbcopy < .state/project_batch_console.js
```

In the same ChatGPT project's Firefox console, first set a two-chat limit. This intentionally exercises Firefox's multiple-download permission:

```javascript
window.__chatProjectBatchLimit = 2;
```

Then paste the clipboard contents and run it. Firefox may ask whether `chatgpt.com` may download multiple files; allow that before a long run.

Confirm the watcher reports successful ingestion and the archive has complete
`versions/<full-id>/<digest>/` bundles, observations and verified current indexes.
Unresolved freshness still needs the bounded recovery described above. A future
live smoke test requires separate operator authorization; automated tests use
synthetic responses and have not established live API behavior.

## 4. Run the remaining queue

Rerun reconciliation after the smoke test so that successfully ingested IDs disappear from the queue:

```bash
ruby reconcile_exports.rb
pbcopy < .state/project_batch_console.js
```

Clear the smoke-test limit in Firefox, then paste the regenerated console program:

```javascript
delete window.__chatProjectBatchLimit;
```

The runner processes one conversation at a time, defaults to roughly one request per minute, honors `Retry-After`, and uses increasing cooldowns after HTTP 429 responses. It does not use concurrency or alternate sessions.

To request a clean stop between conversations:

```javascript
window.__chatProjectBatchStop = true;
```

The browser does not claim a conversation is durably complete merely because it clicked a download link. `capture_watch.rb` plus files already present in `export-chats-data` are authoritative. After any browser interruption, let the watcher drain completed downloads, rerun `ruby reconcile_exports.rb`, and paste the newly generated `.state/project_batch_console.js`.

## 5. Inspect before committing data

After a run, inspect both repositories normally. The tooling repository should
have only ignored `.state/` changes; the data repository should contain additive
`versions/` evidence. Earlier raw/Markdown files must remain unchanged.

If you continue adding manual exports while the batch system is stopped, rerun `ruby reconcile_exports.rb` before restarting so the pending queue incorporates those files.
