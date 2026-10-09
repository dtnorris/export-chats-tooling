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

1. **Inventory** — `project_inventory.js` enumerates the conversations in an
   open ChatGPT Project, downloading conversation IDs, titles, timestamps, and
inventory metadata as JSON and CSV.
2. **Reconcile** — `reconcile_exports.rb` compares that inventory against
   previously archived Markdown and raw JSON, identifies missing conversations,
and generates a pending queue in `.state/`.
3. **Capture** — `project_batch_export.js` retrieves queued conversations
   sequentially in the browser and downloads temporary `AFCHAT_*.json` packages
containing both raw conversation data and rendered Markdown.
4. **Archive** — `capture_watch.rb` monitors the browser's download directory,
   validates capture identities, and atomically saves completed exports into
the separate data repository.
5. **Resume** — Rerunning reconciliation removes successfully archived
   conversation IDs from the pending queue. Interrupted or incomplete exports
remain eligible for subsequent attempts.

The workflow is intentionally incremental: existing exports are reused rather
than blindly downloaded again.

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

`raw/<conversation-id>.json`

Preserves the retrieved conversation response, including available message
structure, metadata, and branching information. This is the canonical archival
representation for future processing.

**Readable Markdown**

`YYYY-MM-DD - <title> [<id-prefix>].md`

Contains visible user/assistant messages from the active conversation branch,
formatted for human reading, search, and LLM consumption. This is a derived
view rather than a complete representation of the raw conversation.

**Inventory and checkpoints**

Project inventories are saved as JSON and CSV. Git-ignored `.state/` files
contain reconciliation results, pending IDs, capture status, and the generated
browser-console batch script.

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
endpoints, which may change. The project-wide workflow currently contains
AdventureFinder-specific assumptions and is not a general account-wide
exporter.

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

---

<!-- Existing daily workflow instructions follow. -->



## **Daily commands to save/scrape chatgpt context**

1. cd /Users/davidnorris/code/export-chats-tooling && ruby capture_watch.rb

2. caffeinate -dimsu

3. cd /Users/davidnorris/code/export-chats-tooling && pbcopy < project_inventory.js
    1. (load the Adventure Finder project page in the UI), (paste the copied JS
       code and run)

4. (move the newly downloaded inventory .json and .csv into:
	1. /Users/davidnorris/code/export-chats-data)

5. cd /Users/davidnorris/code/export-chats-tooling && ruby reconcile_exports.rb
	1. This regenerates .state/project_batch_console.js from the new inventory.

6. cd /Users/davidnorris/code/export-chats-tooling && pbcopy <
   .state/project_batch_console.js
	1. (load the Adventure Finder project page in the UI)
	2. (paste the copied JS code and run)

7. *After the batch finishes:*
	1. cd /Users/davidnorris/code/export-chats-tooling && ruby reconcile_exports.rb
	2. (look to confirm **Pending IDs: 0**)
