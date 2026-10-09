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

The script reads the project ID from the current URL. It supports any project
size, including an empty project, without editing the source. It follows cursors
until the endpoint returns a null or absent cursor (the existing terminal-page
behavior), checks page structure and unique conversation IDs, and refuses
malformed pages, invalid cursors, cursor cycles, empty
pages with another cursor, and runs exceeding the 10,000-page safety limit.
Validation must finish before JSON or CSV downloads are triggered.

For an optional audit against a known total, set this **before** pasting the
script (use your actual expected count):

```javascript
window.__chatProjectInventoryExpectedCount = 500;
```

Only non-negative safe integers are accepted, including `0`. A mismatch stops
the run without downloading inventory files. This setting persists on the page;
clear it before an ordinary incremental inventory:

```javascript
delete window.__chatProjectInventoryExpectedCount;
```

Successful downloads are named
`YYYY-MM-DD - ChatGPT <project-id> Project Inventory.json` and `.csv`.
Long project IDs are shortened in filenames; the manifest retains the full ID.
Move both into your archive directory (by default `../export-chats-data`, which
must already exist). The JSON is used for reconciliation; CSV is for inspection.
The manifest is also available as `window.__chatProjectInventory`; the existing
`window.__adventureFinderProjectInventory` alias and v0.1 schema remain supported.
Without an expected-count assertion, `expected_conversation_count` and
`count_matches_expected` are `null`, meaning the check was not requested.

Cursor exhaustion verifies the listing returned by the endpoint, not an atomic
snapshot of the account or proof that the server omitted nothing. Avoid moving,
adding, or deleting chats during inventory; rerun after project changes or an
interrupted/failed run. Non-OK responses, including HTTP 429, stop the inventory;
wait before retrying.

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

Reconciliation also generates `.state/project_batch_console.js`, which embeds the exact pending queue into the checked-in browser runner. This avoids all cross-origin localhost requests.

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
