# ChatGPT project resumable batch export

This layer keeps the existing single-chat scripts intact. It uses the project inventory stored in the sibling `export-chats-data` repository, conservatively reconciles existing Markdown exports to conversation IDs, and prepares a browser-console runner for only the remaining conversations.

ChatGPT's page Content-Security-Policy blocks page JavaScript from connecting to `127.0.0.1`, so the batch runner deliberately does **not** use a localhost HTTP bridge. Instead, each successful conversation fetch creates one `AFCHAT_*.json` download package containing the raw conversation plus rendered Markdown. A local Ruby watcher ingests those completed downloads into `export-chats-data` atomically.

New captures are written as:

- `raw/<conversation-id>.json` — canonical source response;
- `YYYY-MM-DD - <title> [<id-prefix>].md` — readable active-branch Markdown.

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
JSON remains readable for reconciliation. No versioned capture, changed-content
recapture, deletion, movement, or archival migration is implemented here.

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

Review `.state/reconciliation.json`. The matcher is deliberately conservative: unique normalized titles are accepted, duplicate titles require a matching creation date, and unmatched/ambiguous historical files remain pending. A false negative causes a harmless re-fetch; an uncertain match never suppresses a conversation ID.

Reconciliation also generates .state/project_inventory_console.js for the next
discovery run and .state/project_batch_console.js, which embeds the exact pending queue into the checked-in browser runner. This avoids all cross-origin localhost requests.

## 2. Start the download watcher

```bash
ruby capture_watch.rb
```

By default it watches `~/Downloads` for completed `AFCHAT_*.json` files. Set `CHAT_EXPORT_DOWNLOAD_DIR` or pass a second positional path if Firefox saves elsewhere.

For every valid package the watcher:

1. verifies project and conversation identity against the reconciled queue;
2. writes raw JSON and Markdown atomically into `export-chats-data`;
3. updates `.state/capture_status.json`;
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

Confirm the watcher reports two captured conversations and that `export-chats-data` has the new `raw/<id>.json` plus ID-suffixed Markdown file.

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

After a run, inspect both repositories normally. The tooling repository should have only ignored `.state/` changes; the data repository should contain newly captured Markdown files and `raw/*.json` files.

If you continue adding manual exports while the batch system is stopped, rerun `ruby reconcile_exports.rb` before restarting so the pending queue incorporates those files.
