# ChatGPT Conversation Export Tooling

Browser-based JavaScript and local Ruby utilities for exporting, archiving, and
incrementally preserving personal ChatGPT conversation history.

## Purpose

ChatGPT conversations can accumulate substantial personal and technical
knowledge: research, decisions, implementation history, troubleshooting, and
context that may be valuable long after the original conversation.

This project makes that history **portable, locally accessible, and reusable
outside ChatGPT**, including for search, analysis, future AI-assisted work, and
migration between AI providers.

Originally developed to preserve hundreds of conversations from the
**AdventureFinder** ChatGPT project, the tooling supports both individual-chat
exports and resumable project-wide archival.

## How It Works

The tooling combines JavaScript executed in an authenticated ChatGPT browser
session with Ruby utilities running locally on macOS.

It uses ChatGPT's internal web endpoints to retrieve conversation data through
the existing browser session, without requiring a separate API key. An
alternative DOM-based exporter handles individual conversations by collecting
dynamically loaded page content.

### Project-Wide Export Workflow

1. **Inventory** — project_inventory.js establishes an exhaustive baseline for
   the open project, then uses saved checkpoints for overlapping daily discovery.
JSON/CSV retain every known ID; seven-day audits restore exhaustive listing
coverage.
2. **Reconcile** — `reconcile_exports.rb` compares that inventory against
   previously archived evidence, selects new/updated conversations and a bounded
unknown-freshness bootstrap, and generates a pending queue in `.state/`.
3. **Capture** — `project_batch_export.js` retrieves queued conversations
   sequentially in the browser and downloads temporary `AFCHAT_*.json` packages
containing both raw conversation data and rendered Markdown.
4. **Archive** — `capture_watch.rb` monitors the browser's download directory,
   validates identities/provenance/hashes, and installs complete version bundles into
the separate data repository.
5. **Resume** — Rerunning reconciliation removes successfully archived
   unchanged verified conversations from the pending queue. Interrupted or incomplete exports
remain eligible for subsequent attempts.

Daily discovery depends on the undocumented endpoint's ordering and visibility.
Verified unchanged captures are reused; listing changes trigger content inspection,
with identical raw content deduplicated. Legacy files stay untouched and explicitly
unknown until captured through a ten-ID bootstrap lane. See the
[update/version contract](AUTOMATED_EXPORT.md#daily-update-selection-and-unknown-freshness)
for coverage, digest scope, races, bounded recovery and current/older-version lookup.

An `Ingested ... (unresolved)` message means the content was archived successfully,
but freshness could not be established against the project listing. Valid listing
and fetched timestamps may differ by **up to one second, inclusive**, in either
direction. Neither may be later than request start. Full timestamps remain intact;
even a one-millisecond change to a listing's update time still queues inspection.
The summary
reports **snapshot archives** separately from **freshness verified** IDs. A new
scan does not reset the two-attempt retry limit for unchanged listing fields.
New conversations and first inspections of changed listings run before the bounded
historical recovery lane, newest updates first; that lane may still deliberately
select old chats.

Rerun reconciliation after upgrading to reassess existing complete captures with
this tolerance; no inventory sweep or recapture is required for that reassessment.
Historical observation receipts retain their original schema and freshness value.
The per-ID report's `freshness` field shows today's evaluation; its `current` field
contains the unchanged historical receipt. Raw-only/legacy files without a checked
snapshot still require the existing bootstrap workflow.

### Repository Components

| File | Responsibility | |---|---| | `project_inventory.js` | Project
conversation discovery and inventory | | `reconcile_exports.rb` |
Existing-archive matching, completion accounting, and pending-queue generation
| | `project_batch_export.js` | Rate-limited browser-side batch retrieval and
Markdown rendering | | `capture_watch.rb` | Download validation, atomic
archival, and checkpoint tracking | | `api_export.js` | Single-conversation
export through ChatGPT's internal API | | `scrape.js` / `export.js` | DOM-based
conversation collection and Markdown export | | `AUTOMATED_EXPORT.md` |
Detailed batch operation, smoke testing, and recovery instructions |

## Archived Data

The default archive is maintained in a sibling `export-chats-data` directory,
separate from the tooling repository. (It is recommended to make this sibling
repository into a separate private git repository.)

**Raw conversation JSON**

New captures: `versions/<full-conversation-id>/<raw-content-digest>/raw.json`.
Existing `raw/<conversation-id>.json` files remain readable and unchanged.

Preserves the retrieved conversation response, including available message
structure, metadata, and branching information. This is the canonical archival
representation for future processing.

**Readable Markdown**

New captures: `versions/<full-conversation-id>/<digest>/conversation.md`.
Existing `YYYY-MM-DD - <title> [<id-prefix>].md` files remain in place.

Contains visible user/assistant messages from the active conversation branch,
formatted for human reading, search, and LLM consumption. This is a derived
view rather than a complete representation of the raw conversation.

Each version has checked metadata; immutable observation receipts preserve capture
and inventory provenance, including deduplicated repeats and metadata-only changes.
`versions/<full-id>/current.json` selects the latest complete capture observation,
which may still have unresolved freshness. Source update times do not order versions.
Verify lookup with `SnapshotArchive#current!`/`version!`; restore an older reading by
copying a verified bundle to a fresh directory, preserving all archived files. See
[storage and restoration](AUTOMATED_EXPORT.md#version-storage-digest-and-current-lookup).

**Inventory and checkpoints**

Project inventories are saved as cumulative JSON checkpoints and inspection
CSV. Git-ignored .state/ files contain reconciliation results, pending IDs,
capture status, and generated inventory/batch console scripts. Retain previous
JSONs for recovery; CSV alone cannot authorize daily scans.

### Import local Codex agent sessions

`import_codex_sessions.rb` archives local Codex rollout JSONL files alongside
the ChatGPT exports. It does not use the browser exporter, network, or `.state`.
The original bytes go to `raw/codex/<full-session-id>.jsonl`; a readable
`YYYY-MM-DD - <recorded-task-heading> [<id-prefix>].md` goes at the data
repository root. The Markdown records the full session ID, start time, source
file, status, and SHA-256 of its authoritative raw file. The date is the local
start date encoded in the rollout filename (checked against the session's UTC
timestamp); if absent, the UTC date is used. A heading explicitly present in a
user message supplies the title; otherwise the title is `Codex Session <prefix>`.

The importer reads `response_item` messages and paired tool calls/results in
file order. `event_msg.item_completed` repeats some of the same activity, so
user/agent messages are not rendered twice; command, file change, extension,
and nested tool diagnostics appear as distinct execution entries. Long tool
arguments and outputs remain complete in collapsible blocks. Developer
instructions and internal reasoning do not enter the readable view. The raw
JSONL retains them, along with full event records, accounting, and non-text
payloads. No transcript synthesis or LLM title generation is performed.

Run these from the tooling checkout. The default source is
`~/.codex/sessions`, recursively including existing and future year/month
folders. `--source` can restrict a run to a particular subtree. The default
destination is the sibling private `export-chats-data` checkout, which must
already exist.

```bash
# Import completed Codex sessions from previous days.
# --settled-only skips today's sessions and files modified within the last 2 hours,
# reducing the risk of archiving an active or recently resumed session.

cd /Users/davidnorris/code/export-chats-tooling

# 1. Preview eligible imports without changing the archive.
ruby import_codex_sessions.rb \
  --source /Users/davidnorris/.codex/sessions \
  --data-repo /Users/davidnorris/code/export-chats-data \
  --settled-only --dry-run

# 2. Import eligible sessions.
ruby import_codex_sessions.rb \
  --source /Users/davidnorris/.codex/sessions \
  --data-repo /Users/davidnorris/code/export-chats-data \
  --settled-only

# 3. Verify idempotency: imported=0, failed=0, conflicting=0.
ruby import_codex_sessions.rb \
  --source /Users/davidnorris/.codex/sessions \
  --data-repo /Users/davidnorris/code/export-chats-data \
  --settled-only --dry-run
```

**Note:** `--settled-only` is a conservative daily-import safeguard, not proof that a session is permanently complete. Older Codex sessions can still be resumed. The importer preserves existing archives and rejects changed same-ID content rather than silently overwriting it. Sessions with colliding short-ID filename prefixes receive distinct Markdown filenames.

For routine incremental imports, use `ruby
import_codex_sessions.rb --dry-run` to review, followed by `ruby
import_codex_sessions.rb`. `--verbose` also lists unchanged sessions; `--help`
shows the CLI. A second import of identical source bytes leaves existing files
untouched. A changed rollout with the same ID, duplicate source IDs, different
existing Markdown, malformed records, or unsafe paths produces an explicit
failure and nonzero exit. Incomplete sessions are labeled as such; subsequent
growth is detected as a same-ID conflict rather than silently overwriting the
earlier snapshot. After inspecting the old and new raw files, retain the old
snapshot separately and move its raw and Markdown pair out of the archive
before re-importing that session. There is no automatic update or deletion.
If a run stops after its raw write but before Markdown is installed, rerun:
an identical raw file is accepted and the missing Markdown is created.

Verify an import by checking the printed counts and paths, comparing
`shasum -a 256` on an original JSONL and its `raw/codex/` copy, then rerunning
and confirming `unchanged` equals `discovered` with zero conflicts/failures.
The parser rejects unknown response or execution item structures until their
meaning is reviewed. It does not inline internal reasoning, developer messages,
binary assets, full duplicate event representations, or token accounting in
Markdown; inspect the lossless raw file for those. Keep the data checkout and
source sessions private. The public tooling checkout contains only synthetic
test data. Never delete original Codex sessions as a consequence of importing.

Tests: `ruby -I. test/import_codex_sessions_test.rb` from this checkout.

## Reliability and Recovery

The batch exporter processes one conversation at a time, with approximately
60-second request spacing, HTTP 429 handling, `Retry-After` support, and
increasing cooldowns. It does not attempt parallel requests or
alternate-session rate-limit circumvention.

Archival is deliberately conservative:

- Ambiguous historical matches remain pending rather than being assumed
  complete.
- Project and conversation identities are validated before ingestion.
- Existing files with different contents are never silently overwritten.
- Raw JSON and Markdown are written atomically; capture checkpoints include
  SHA-256 digests.
- Browser-triggered downloads do not count as completed archives until locally
  ingested.
- Interrupted runs can resume after reconciliation without restarting the
  entire collection.

## Scope and Limitations

This is **unofficial, personal-use tooling**, not OpenAI's supported
account-data export service.

It relies on ChatGPT's authenticated web interface and undocumented internal
endpoints, which may change. Project inventory uses the ID of the open ChatGPT
Project and supports any conversation count, with an optional exact-count audit.
Partial discovery assumes descending update ordering across the unseen suffix;
a locally ordered prefix cannot establish it. Seven-day audits bound recovery
for visible backdated records during successful daily operation. Pagination
checks cannot prove an atomic server snapshot or recover records never exposed. This is not a general account-wide exporter. Historical
AdventureFinder schema names remain for compatibility, and checkpoints support
one project per tooling checkout.

Markdown captures supported visible conversation text; images, audio, and other
non-text content may appear as placeholders rather than original media. The raw
JSON preserves the available API response but is not a guarantee that every
associated asset has been downloaded.

Exported conversations may contain sensitive personal or proprietary
information. Keep archived data private, review the browser scripts before
execution, and do not confuse the public tooling repository with the separate
personal data archive.

## Usage

See the daily workflow below for routine incremental exports, or
[AUTOMATED_EXPORT.md](AUTOMATED_EXPORT.md) for setup, the initial
two-conversation smoke test, browser-console execution, and interruption
recovery.

Offline inventory regression tests use Node.js 18 or later:

```bash
node --test test/project_inventory.test.js
ruby -I. test/reconcile_exports_test.rb
ruby -I. test/snapshot_archive_test.rb
ruby -I. test/capture_watch_test.rb
ruby -I. test/import_codex_sessions_test.rb
```

---




## Daily export quick reference (macOS)

Run commands from your `export-chats-tooling` checkout. Keep a separate archive
directory; the default is `../export-chats-data`. See
[AUTOMATED_EXPORT.md](AUTOMATED_EXPORT.md) for explicit archive/inventory paths
and instructions for keeping projects separate.

1. Keep the Mac awake. Run this in a separate terminal and leave it running until the export is complete:
    - `caffeinate -dimsu`

2. Refresh the project inventory.
    - (Open the ChatGPT Project you want to archive, paste the copied JavaScript into its developer console, and run it.)
    - (No expected count is required. If you previously enabled the optional audit, clear it with `delete window.__chatProjectInventoryExpectedCount` first.)
    - `cd /Users/davidnorris/code/export-chats-tooling && pbcopy < project_inventory.js`
    - `cd /Users/davidnorris/code/export-chats-tooling && pbcopy < .state/project_inventory_console.js`
    - `cd /Users/davidnorris/code/export-chats-tooling && pbcopy < .state/project_batch_console.js`
    - First run: copy project_inventory.js from the tooling checkout.
    - Later runs: copy .state/project_inventory_console.js after reconciliation.
    - Use pbcopy < the chosen script, then paste it into the browser console.
    - A full audit is automatic every seven days. Set window.__chatProjectInventoryFullAudit = true to force one, then clear it afterward.

3. (Move the newly downloaded inventory JSON and CSV files into:)
    - Your archive directory (default: `/Users/davidnorris/code/export-chats-data`).

4. Generate the current pending queue and browser exporter.
    - (This regenerates the next inventory console script and batch exporter. Review freshness states: Pending IDs: 0 can coexist with unknown/deferred IDs and does not establish unseen-record discovery.)
    - `cd /Users/davidnorris/code/export-chats-tooling && ruby reconcile_exports.rb`

5. Start the capture watcher in a separate terminal.
    - (Start it after reconciliation: it loads the queue only at startup. An initially empty queue reports completion and exits successfully without scanning Downloads. An initially nonempty watcher keeps running after ingestion; restart it before exporting with a newly generated queue. `--once` still scans twice, even for an empty queue.)
    - `cd /Users/davidnorris/code/export-chats-tooling && ruby capture_watch.rb`

6. Copy and run the generated browser exporter.
    - (Open the same ChatGPT Project, paste the copied JavaScript into the browser’s developer console, and run it. Follow the documented two-chat smoke test before a first full run.)
    - `cd /Users/davidnorris/code/export-chats-tooling && pbcopy < .state/project_batch_console.js`

7.  Wait for local ingestion to finish.
    - (After the browser batch finishes, let the watcher finish processing all completed downloads. Rejected files remain in Downloads, with one warning per unchanged file/error per process. Changed files stabilize and undergo full validation again; restarting can report rejects again. Check its output, then stop the watcher with Ctrl-C.)

8. Verify the archive.
    - `cd /Users/davidnorris/code/export-chats-tooling && ruby reconcile_exports.rb`
    - (Review snapshot archives, freshness verified, queue reasons, and per-ID freshness states. An archived snapshot can have unresolved freshness. Unresolved root Markdown includes unmatched Codex exports and is not a missing-chat count. Partial discovery has conditional coverage; full audits recover visible records outside overlap.)
    - (If IDs remain, investigate the watcher and browser output before retrying. Start a fresh watcher before running the regenerated exporter.)
    - (When finished, stop caffeinate with Ctrl-C in its terminal.)

For a retrospective day, use the existing local-date scope with the intended
timezone, for example `TZ=America/New_York CHAT_EXPORT_ONLY_LOCAL_DATE=2026-10-21 ruby reconcile_exports.rb`.
This selects known conversations whose latest listing update falls on that date;
it is not an independent discovery audit or proof of every message written that day.
An exhaustive inventory establishes what the endpoint exposed at scan time;
compare its IDs against the generated per-ID freshness report before claiming the
day is fully captured. A changed listing with an older saved snapshot still needs
capture even if the ID already has archived files.
Date scope can fail closed when active IDs remain unresolved and deferred by the
recovery budget; use unscoped reconciliation to inspect that situation.


## 10/23 Notes (Full Reset)
1. caffeinate -dimsu
2. delete window.__chatProjectInventoryExpectedCount; window.__chatProjectInventoryFullAudit = true;
3. cd /Users/davidnorris/code/export-chats-tooling && git status --short && pbcopy < .state/project_inventory_console.js
4. <move the downloads in export-chats-data>
5. cd /Users/davidnorris/code/export-chats-tooling &&
env -u CHAT_EXPORT_ONLY_LOCAL_DATE ruby reconcile_exports.rb /Users/davidnorris/code/export-chats-data "/Users/davidnorris/code/export-chats-data/2026-10-23 - ChatGPT g-p-6a75a7bb03108191bac6b26aa275267e Project Inventory.json"
6. cd /Users/davidnorris/code/export-chats-tooling && ruby capture_watch.rb /Users/davidnorris/code/export-chats-data
7. delete window.__chatProjectBatchLimit;
8. cd /Users/davidnorris/code/export-chats-tooling && pbcopy < .state/project_batch_console.js

## 10/23 Notes (Tonight)
1. caffeinate -dimsu
2. delete window.__chatProjectInventoryExpectedCount; delete window.__chatProjectInventoryFullAudit;
3. cd /Users/davidnorris/code/export-chats-tooling && pbcopy < .state/project_inventory_console.js
4. <move the downloads in export-chats-data>
5. cd /Users/davidnorris/code/export-chats-tooling && env -u CHAT_EXPORT_ONLY_LOCAL_DATE ruby reconcile_exports.rb && /Users/davidnorris/code/export-chats-data && "/Users/davidnorris/code/export-chats-data/2026-10-23 - AdventureFinder Nightly Project Inventory.json"
6. cd /Users/davidnorris/code/export-chats-tooling && ruby capture_watch.rb && /Users/davidnorris/code/export-chats-data && /Users/davidnorris/Downloads
7. delete window.__chatProjectBatchLimit;
8. cd /Users/davidnorris/code/export-chats-tooling && pbcopy < .state/project_batch_console.js
9. <after> cd /Users/davidnorris/code/export-chats-tooling && env -u CHAT_EXPORT_ONLY_LOCAL_DATE ruby reconcile_exports.rb && /Users/davidnorris/code/export-chats-data && "/Users/davidnorris/code/export-chats-data/2026-10-23 - AdventureFinder Nightly Project Inventory.json"
