# AdventureFinder resumable batch export

This layer keeps the existing single-chat scripts intact. It uses the project inventory stored in the sibling `export-chats-data` repository, conservatively reconciles existing Markdown exports to conversation IDs, and prepares a browser-console runner for only the remaining conversations.

ChatGPT's page Content-Security-Policy blocks page JavaScript from connecting to `127.0.0.1`, so the batch runner deliberately does **not** use a localhost HTTP bridge. Instead, each successful conversation fetch creates one `AFCHAT_*.json` download package containing the raw conversation plus rendered Markdown. A local Ruby watcher ingests those completed downloads into `export-chats-data` atomically.

New captures are written as:

- `raw/<conversation-id>.json` — canonical source response;
- `YYYY-MM-DD - <title> [<id-prefix>].md` — readable active-branch Markdown.

Runtime/checkpoint files live under `export-chats-tooling/.state/` and are ignored by Git.

## 1. Reconcile the existing archive

From `/Users/davidnorris/code/export-chats-tooling`:

```bash
ruby reconcile_exports.rb
```

The default sibling data repository is `/Users/davidnorris/code/export-chats-data`. An explicit data path and inventory path may also be supplied as the first and second arguments.

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

In the open AdventureFinder project's Firefox console, first set a two-chat limit. This intentionally exercises Firefox's multiple-download permission:

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
