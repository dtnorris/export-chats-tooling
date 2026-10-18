"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const { webcrypto, createHash } = require("node:crypto");
const { spawnSync } = require("node:child_process");

const source = fs.readFileSync(path.join(__dirname, "../project_inventory.js"), "utf8");
const projectId = "g-p-test-project";
const item = id => ({ id, title: `Chat ${id}`, create_time: 1, update_time: 2 });

// Execute the browser program with synthetic session/page responses.
// Capture actual download payloads; no live account or network is used.
async function inventoryRun(pages, options = {}) {
  const requests = [];
  const downloads = [];
  const logs = [];
  const blobs = new Map();
  const delays = [];
  /** Fixed wall clock for deterministic scan/audit boundaries; behaves like Date otherwise. */
  class FixtureDate extends Date {
    constructor(...args) { super(...(args.length ? args : [options.now || "2026-10-10T12:00:00.000Z"])); }
    static now() { return new FixtureDate().getTime(); }
  }
  const window = {
    __chatProjectInventory: { stale: true },
    __adventureFinderProjectInventory: { stale: true },
    __chatProjectInventoryExpectedCount: options.expected,
    __chatProjectInventoryPrevious: options.previous,
    __chatProjectInventoryFullAudit: options.fullAudit
  };
  class BrowserURL extends URL {
    static createObjectURL(blob) {
      const url = `blob:test-${blobs.size}`;
      blobs.set(url, blob);
      return url;
    }
    static revokeObjectURL() {}
  }
  const sandbox = {
    window,
    location: { href: options.href || `https://chatgpt.com/${projectId}/project` },
    URL: BrowserURL,
    URLSearchParams,
    Blob,
    TextDecoder,
    TextEncoder,
    crypto: webcrypto,
    Date: FixtureDate,
    atob,
    console: Object.fromEntries(["log", "error", "warn"].map(method =>
      [method, (...args) => logs.push(args)])),
    setTimeout: (callback, ms) => { delays.push(ms); queueMicrotask(callback); return 1; },
    document: {
      body: { appendChild() {} },
      createElement: () => ({
        style: {},
        click() { downloads.push({ filename: this.download, blob: blobs.get(this.href) }); },
        remove() {}
      })
    },
    fetch: async (url, init) => {
      requests.push({ url, init });
      if (url === "/api/auth/session") {
        return { ok: true, json: async () => (options.session || { accessToken: "synthetic", account: { id: "account-test" } }) };
      }
      const index = requests.length - 2;
      const page = typeof pages === "function" ? pages(index) : pages[index];
      if (page === undefined) throw new Error(`Unexpected page request ${index}`);
      if (page?.httpError) {
        return { ok: false, status: page.httpError, statusText: "Test error", text: async () => "" };
      }
      return { ok: true, json: async () => page };
    }
  };
  let error;
  try {
    await vm.runInNewContext(options.source || source, sandbox, { timeout: 1000 });
  } catch (caught) {
    error = caught;
  }
  for (const download of downloads) download.text = await download.blob.text();
  return { error, requests, downloads, logs, window, delays };
}

/** Assert fail-closed output for a rejected synthetic run; throws assertion errors. */
function assertRefused(result, message) {
  assert.ok(result.error, "run must fail");
  assert.match(result.error.message, message);
  assert.equal(result.downloads.length, 0, "failed runs must not trigger downloads");
  assert.equal(result.window.__chatProjectInventory, undefined);
  assert.equal(result.window.__adventureFinderProjectInventory, undefined);
}

test("inventories below and above the former 462 limit, including zero", async () => {
  for (const count of [0, 1, 461, 462, 463, 500]) {
    const items = Array.from({ length: count }, (_, i) => item(`id-${i}`));
    const pages = count > 250
      ? [{ items: items.slice(0, 250), cursor: "next" }, { items: items.slice(250), cursor: null }]
      : [{ items, cursor: null }];
    const result = await inventoryRun(pages);
    assert.equal(result.error, undefined);
    assert.equal(result.downloads.length, 2);
    const manifest = JSON.parse(result.downloads[0].text);
    assert.equal(manifest.project_id, projectId);
    assert.equal(manifest.observed_conversation_count, count);
    assert.equal(manifest.conversations.length, count);
    assert.equal(manifest.expected_conversation_count, null);
    assert.equal(manifest.count_matches_expected, null);
    assert.equal(manifest.page_count, pages.length);
    assert.deepEqual(manifest.raw_pages, pages);
    assert.equal(result.window.__chatProjectInventory, result.window.__adventureFinderProjectInventory);
    for (const [index, download] of result.downloads.entries()) {
      assert.match(download.filename, new RegExp(`^\\d{4}-\\d{2}-\\d{2} - ChatGPT ${projectId} Project Inventory\\.${index ? "csv" : "json"}$`));
    }
    assert.equal(result.downloads[1].text.trim().split("\n").length, count + 1);
    for (const request of result.requests.slice(1)) {
      assert.equal(request.init.headers["chatgpt-project-id"], projectId);
      assert.equal(request.init.headers["ChatGPT-Account-ID"], "account-test");
      assert.equal(request.init.headers.Authorization, "Bearer synthetic");
    }
    if (pages.length === 2) assert.match(result.requests[2].url, /cursor=next$/);
  }
});

test("optional exact count accepts a matching total, including zero", async () => {
  for (const count of [0, 2]) {
    const result = await inventoryRun([{ items: Array.from({ length: count }, (_, i) => item(`${i}`)), cursor: null }], { expected: count });
    assert.equal(result.error, undefined);
    const manifest = JSON.parse(result.downloads[0].text);
    assert.equal(manifest.expected_conversation_count, count);
    assert.equal(manifest.count_matches_expected, true);
  }
});

test("null disables the optional count check", async () => {
  const result = await inventoryRun([{ items: [], cursor: null }], { expected: null });
  assert.equal(result.error, undefined);
  assert.equal(JSON.parse(result.downloads[0].text).count_matches_expected, null);
});

test("mismatching audit count fails before publication or download", async () => {
  assertRefused(await inventoryRun([{ items: [item("a")], cursor: null }], { expected: 2 }), /count mismatch/);
});

test("invalid count options fail before any request", async () => {
  for (const expected of [-1, 1.5, "2", false, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    const result = await inventoryRun([], { expected });
    assertRefused(result, /non-negative safe integer/);
    assert.equal(result.requests.length, 0);
  }
});

test("duplicate IDs across pages fail closed", async () => {
  assertRefused(await inventoryRun([
    { items: [item("a")], cursor: "next" },
    { items: [item("a")], cursor: null }
  ]), /Duplicate conversation ID/);
});

test("cursor cycles fail closed", async () => {
  assertRefused(await inventoryRun([{ items: [item("a")], cursor: "0" }]), /Cursor cycle/);
});

test("empty pages with another cursor fail closed", async () => {
  assertRefused(await inventoryRun([{ items: [], cursor: "next" }]), /empty project page/);
});

test("an absent terminal cursor remains supported for compatibility", async () => {
  for (const items of [[], [item("a")]]) {
    const result = await inventoryRun([{ items }]);
    assert.equal(result.error, undefined);
    assert.equal(JSON.parse(result.downloads[0].text).observed_conversation_count, items.length);
  }
});

test("invalid cursors fail closed", async () => {
  for (const cursor of ["", "   ", 7, false, {}]) {
    assertRefused(await inventoryRun([{ items: [item("a")], cursor }]), /invalid next cursor/);
  }
});

test("malformed pages fail closed", async () => {
  for (const page of [null, {}, { items: {}, cursor: null }]) {
    assertRefused(await inventoryRun([page]), /items array/);
  }
});

test("missing or unusable conversation IDs fail closed", async () => {
  for (const entry of [null, {}, item(""), item("  "), item(9)]) {
    assertRefused(await inventoryRun([{ items: [entry], cursor: null }]), /usable conversation ID/);
  }
});

test("HTTP errors after a valid page do not export a partial inventory", async () => {
  for (const httpError of [401, 429, 500]) {
    assertRefused(await inventoryRun([
      { items: [item("a")], cursor: "next" }, { httpError }
    ]), new RegExp(`${httpError} Test error`));
  }
});

test("the finite page limit refuses an endless listing", async () => {
  const result = await inventoryRun(i => ({ items: [item(`id-${i}`)], cursor: `cursor-${i}` }));
  assertRefused(result, /Safety page limit/);
  assert.equal(result.requests.length, 10001); // one session request + 10,000 pages
});

test("non-project pages fail before requesting a session", async () => {
  const result = await inventoryRun([], { href: "https://chatgpt.com/" });
  assertRefused(result, /open ChatGPT project page/);
  assert.equal(result.requests.length, 0);
});

test("downloaded CSV preserves quotes, commas, and multiline titles", async () => {
  const entry = { ...item("a"), title: 'A, "quoted"\nchat' };
  const result = await inventoryRun([{ items: [entry], cursor: null }]);
  assert.equal(result.error, undefined);
  assert.equal(JSON.parse(result.downloads[0].text).conversations[0].title, entry.title);
  assert.ok(result.downloads[1].text.includes('"A, ""quoted""\nchat"'));
});

test("long project URL IDs retain the discoverable inventory filename suffix", async () => {
  const longId = `g-p-${"a".repeat(220)}`;
  const result = await inventoryRun([{ items: [], cursor: null }], {
    href: `https://chatgpt.com/${longId}/project`
  });
  assert.equal(result.error, undefined);
  assert.equal(JSON.parse(result.downloads[0].text).project_id, longId);
  assert.match(result.downloads[0].filename, / Project Inventory\.json$/);
  assert.ok(result.downloads[0].filename.length < 180);
});

const DAY = 86400000;
const BASE_TIME = "2026-10-10T12:00:00.000Z";
const NEXT_DAY = "2026-10-11T12:00:00.000Z";

/** Return a deterministic ISO timestamp offset from the baseline clock. */
function atOffset(milliseconds) {
  return new Date(Date.parse(BASE_TIME) + milliseconds).toISOString();
}

/** Paginate synthetic records with explicit terminal/cursor evidence; returns pages. */
function listing(records, pageSize = 10) {
  if (!records.length) return [{ items: [], cursor: null }];
  const pages = [];
  for (let index = 0; index < records.length; index += pageSize) {
    pages.push({ items: records.slice(index, index + pageSize), cursor: index + pageSize < records.length ? "page-" + pages.length : null });
  }
  return pages;
}

/** Build 500 dated records, one per day; no real archive or endpoint data. */
function largeFixture() {
  return Array.from({ length: 500 }, (_, index) => ({
    id: "id-" + index, title: "Chat " + index,
    create_time: atOffset(-index * DAY), update_time: atOffset(-index * DAY)
  }));
}

/** Read an actual downloaded manifest, asserting the browser run succeeded. */
function manifest(result) {
  assert.equal(result.error, undefined, result.error?.stack);
  return JSON.parse(result.downloads[0].text);
}

/** Produce an isolated baseline checkpoint from the same synthetic listing path. */
async function baseline(records = largeFixture()) {
  return manifest(await inventoryRun(listing(records)));
}

/** Re-sign deliberately malformed metadata to exercise validation beyond corruption detection. */
function resign(inventory) {
  const { checkpoint_sha256, ...payload } = inventory;
  const encoderSource = source.slice(source.indexOf("  function checkpointEncoding("), source.indexOf("  /** Hash the typed checkpoint"));
  const encode = vm.runInNewContext("(" + encoderSource.trim() + ")");
  inventory.checkpoint_sha256 = createHash("sha256").update(encode(payload)).digest("hex");
  return inventory;
}

test("500-chat fixture: full=50 listings, daily=2; exceeds predeclared 80% reduction", async () => {
  const records = largeFixture();
  const full = await inventoryRun(listing(records));
  const prior = manifest(full);
  assert.equal(full.requests.length - 1, 50); // excludes session, old exhaustive algorithm
  assert.equal(prior.coverage, "exhaustive");
  assert.equal(prior.full_audit.observed_count, 500);
  const updated = records.map(entry => entry.id === "id-499"
    ? { ...entry, title: "Old chat recently updated", update_time: atOffset(DAY / 2) } : entry);
  updated.push(
    { ...item("new-1"), update_time: atOffset(DAY - 1000) },
    { ...item("new-2"), update_time: atOffset(DAY - 2000) },
    { ...item("delayed"), update_time: atOffset(-6 * DAY) }
  );
  updated.sort((left, right) => Date.parse(right.update_time) - Date.parse(left.update_time));
  const daily = await inventoryRun(listing(updated), { previous: prior, now: NEXT_DAY });
  const current = manifest(daily);
  assert.equal(current.coverage, "incremental");
  assert.equal(daily.requests.length - 1, 2);
  assert.ok((daily.requests.length - 1) <= 50 * 0.2);
  assert.equal(current.observed_conversation_count, 20);
  assert.equal(current.known_conversation_count, 503);
  assert.equal(current.raw_pages.length, 2);
  assert.deepEqual(current.full_audit, prior.full_audit);
  assert.equal(current.cutoff, atOffset(-7 * DAY));
  for (const id of ["new-1", "new-2", "delayed", "id-499"]) {
    assert.equal(current.conversations.find(entry => entry.id === id).observed_in_scan, true);
  }
  const old = current.conversations.find(entry => entry.id === "id-400");
  assert.equal(old.observed_in_scan, false);
  assert.equal(old.last_observed_at, BASE_TIME);
  assert.equal(current.conversations.find(entry => entry.id === "id-499").title, "Old chat recently updated");
  assert.equal(daily.delays.filter(ms => ms === 1000).length, 1);
  assert.equal(daily.requests.filter(request => request.url === "/api/auth/session").length, 1);
  assert.ok(!JSON.stringify(current).includes("synthetic"));
  assert.ok(!JSON.stringify(daily.logs).includes("Bearer"));

  // The next checkpoint also supports another daily run without changing audit lineage.
  const next = manifest(await inventoryRun(listing(updated), { previous: current, now: atOffset(2 * DAY) }));
  assert.equal(next.coverage, "incremental");
  assert.deepEqual(next.full_audit, prior.full_audit);

  // A subsequent audit observes all current IDs but preserves a no-longer-listed ID.
  const auditRecords = updated.filter(entry => entry.id !== "id-400");
  const audited = manifest(await inventoryRun(listing(auditRecords), { previous: next, now: atOffset(7 * DAY) }));
  assert.equal(audited.coverage, "exhaustive");
  assert.equal(audited.scan_reason, "audit-due");
  assert.equal(audited.observed_conversation_count, 502);
  assert.equal(audited.known_conversation_count, 503);
  assert.equal(audited.conversations.find(entry => entry.id === "id-400").observed_in_scan, false);
  assert.notEqual(audited.full_audit.id, prior.full_audit.id);
});

test("all cutoff ties are scanned; just-beyond and backdated additions wait for audit", async () => {
  const cutoff = atOffset(-7 * DAY);
  const records = Array.from({ length: 25 }, (_, index) => ({
    ...item("tie-" + index), update_time: index < 20 ? cutoff : atOffset(-7 * DAY - 1)
  }));
  const prior = await baseline(records);
  // First page is all ties; second is all ties; third is below cutoff and stops.
  // The unseen fourth page starts only one millisecond beyond the overlap.
  const additions = [
    ...records,
    ...Array.from({ length: 5 }, (_, index) => ({ ...item("padding-" + index), update_time: atOffset(-7 * DAY - 1) })),
    { ...item("just-beyond"), update_time: atOffset(-7 * DAY - 1) },
    { ...item("backdated"), update_time: atOffset(-100 * DAY) }
  ];
  const daily = await inventoryRun(listing(additions), { previous: prior, now: NEXT_DAY });
  const current = manifest(daily);
  assert.equal(daily.requests.length - 1, 3);
  assert.ok(current.conversations.filter(entry => entry.id.startsWith("tie-")).every(entry => entry.observed_in_scan));
  assert.ok(!current.conversations.some(entry => entry.id === "just-beyond"));
  assert.ok(!current.conversations.some(entry => entry.id === "backdated"));
  const audit = manifest(await inventoryRun(listing(additions), { previous: current, now: atOffset(7 * DAY) }));
  assert.equal(audit.coverage, "exhaustive");
  for (const id of ["just-beyond", "backdated"]) assert.ok(audit.conversations.some(entry => entry.id === id && entry.observed_in_scan));
});

test("missing checkpoint, forced, expected-count, due and stale audits exhaust pagination", async () => {
  const prior = await baseline();
  for (const options of [
    {}, { previous: prior, fullAudit: true, now: NEXT_DAY },
    { previous: prior, expected: 500, now: NEXT_DAY },
    { previous: prior, now: atOffset(7 * DAY) },
    { previous: prior, now: atOffset(70 * DAY) }
  ]) {
    const result = await inventoryRun(listing(largeFixture()), options);
    const current = manifest(result);
    assert.equal(current.coverage, "exhaustive");
    assert.equal(result.requests.length - 1, 50);
  }
  const empty = await baseline([]);
  assert.equal(manifest(await inventoryRun(listing([]), { previous: empty, now: NEXT_DAY })).coverage, "exhaustive");
});

test("legacy/mismatched/corrupt checkpoints refuse without replacing prior evidence", async () => {
  const prior = await baseline();
  const cases = [
    { ...prior, schema: "adventurefinder-chat-project-inventory/v0.1" },
    { ...prior, account_id: "other-account" }, { ...prior, project_id: "other-project" },
    { ...prior, producer: "unknown" }, { ...prior, full_audit: null },
    { ...prior, conversations: [] }, {}, [], "broken"
  ];
  for (const previous of cases) {
    const original = JSON.stringify(previous);
    const result = await inventoryRun([], { previous, now: NEXT_DAY });
    assertRefused(result, /Previous inventory/);
    assert.equal(result.requests.length, 1);
    assert.equal(JSON.stringify(result.window.__chatProjectInventoryPrevious), original);
  }
  for (const change of [
    { coverage: "partial" }, { full_audit: { ...prior.full_audit, observed_count: 499 } },
    { watermark: NEXT_DAY }, { page_count: 51 }, { observed_conversation_count: 499 },
    { overlap_ms: 1 }, { known_conversation_count: 1 }
  ]) {
    assertRefused(await inventoryRun([], { previous: resign({ ...prior, ...change }), now: NEXT_DAY }), /Previous inventory/);
  }
});

test("unusable baseline timestamp evidence forces full scans, never a stopping watermark", async () => {
  for (const update_time of [null, "bad", NaN, Infinity, 1e20]) {
    const records = [{ ...item("unknown-date"), update_time }, ...largeFixture()];
    const prior = await baseline(records);
    assert.equal(prior.full_audit.timestamps_usable, false);
    // JSON cannot represent NaN/infinity. Such corrupt raw evidence is refused safely.
    if (!Number.isFinite(update_time) && typeof update_time === "number" && update_time !== 1e20) continue;
    const result = await inventoryRun(listing(records), { previous: prior, now: NEXT_DAY });
    assert.equal(manifest(result).coverage, "exhaustive");
    assert.equal(result.requests.length - 1, 51);
  }
});

test("observed ordering anomalies and missing times fall back to exhaustive traversal", async () => {
  const prior = await baseline();
  for (const variant of ["within", "across", "missing"]) {
    const records = largeFixture();
    if (variant === "within") records[1].update_time = atOffset(1000);
    if (variant === "across") records[10].update_time = atOffset(1000);
    if (variant === "missing") records[0].update_time = null;
    // Hour-spaced prefix ensures cross-page disorder is encountered before cutoff.
    if (variant === "across") {
      for (let index = 0; index < 10; index++) records[index].update_time = atOffset(-index * 3600000);
    }
    const result = await inventoryRun(listing(records), { previous: prior, now: NEXT_DAY });
    const current = manifest(result);
    assert.equal(current.coverage, "exhaustive");
    assert.match(current.scan_reason, /fallback/);
    assert.equal(result.requests.length - 1, 50);
    assert.ok(!current.full_audit.ordered || !current.full_audit.timestamps_usable);
  }
});

test("a locally ordered prefix cannot establish unseen suffix ordering; audits recover", async () => {
  const prior = await baseline();
  const records = largeFixture();
  records.push({ ...item("unseen-reordered"), update_time: atOffset(DAY / 2) });
  const current = manifest(await inventoryRun(listing(records), { previous: prior, now: NEXT_DAY }));
  assert.equal(current.coverage, "incremental");
  assert.ok(!current.conversations.some(entry => entry.id === "unseen-reordered"));
  const audit = manifest(await inventoryRun(listing(records), { previous: current, fullAudit: true, now: atOffset(2 * DAY) }));
  assert.equal(audit.coverage, "exhaustive");
  assert.equal(audit.full_audit.ordered, false);
  assert.ok(audit.conversations.some(entry => entry.id === "unseen-reordered"));
});

test("daily page bound continues exhaustive scan instead of unbounded fast success", async () => {
  const records = Array.from({ length: 1001 }, (_, index) => ({ ...item("dense-" + index), update_time: BASE_TIME }));
  const prior = await baseline(records);
  const result = await inventoryRun(listing(records), { previous: prior, now: NEXT_DAY });
  const current = manifest(result);
  assert.equal(result.requests.length - 1, 101);
  assert.equal(current.coverage, "exhaustive");
  assert.equal(current.scan_reason, "daily-page-bound-fallback");
});

test("incremental failures preserve checkpoint and never publish partial or merged output", async () => {
  const prior = await baseline();
  for (const badPage of [
    { httpError: 429 }, { httpError: 401 }, { httpError: 500 }, {},
    { items: [item("duplicate"), item("duplicate")], cursor: null },
    { items: [], cursor: "next" }, { items: [item("a")], cursor: 9 },
    { items: [item("a")], cursor: "0" }
  ]) {
    const result = await inventoryRun([badPage], { previous: prior, now: NEXT_DAY });
    assertRefused(result, /./);
    assert.deepEqual(result.window.__chatProjectInventoryPrevious, prior);
    assert.equal(result.requests.length - 1, 1);
    assert.equal(result.delays.filter(ms => ms === 1000).length, 0);
  }
  assertRefused(await inventoryRun(listing(largeFixture()), { previous: prior, expected: 503, now: NEXT_DAY }), /count mismatch/);
});

test("strict timestamp normalization retains JSON/CSV evidence without invented dates", async () => {
  const valid = [
    [0, "1970-01-01T00:00:00.000Z"], [0.0004999999999999999, "1970-01-01T00:00:00.000Z"],
    [0.0005, "1970-01-01T00:00:00.001Z"], [-0.0005, "1970-01-01T00:00:00.000Z"], [1.125, "1970-01-01T00:00:01.125Z"],
    [-0.001, "1969-12-31T23:59:59.999Z"],
    [-62135596800, "0001-01-01T00:00:00.000Z"],
    [253402300799.999, "9999-12-31T23:59:59.999Z"],
    ["2024-02-29T12:34:56Z", "2024-02-29T12:34:56.000Z"],
    ["1582-10-10T12:00:00Z", "1582-10-10T12:00:00.000Z"],
    ["2026-10-10T14:00:00.1+02:00", "2026-10-10T12:00:00.100Z"],
    ["2026-10-10T08:30:00.12-03:30", "2026-10-10T12:00:00.120Z"],
    ["2026-10-11T02:00:00+14:00", "2026-10-10T12:00:00.000Z"]
  ];
  const missing = [undefined, null, ""];
  const invalid = [NaN, Infinity, -Infinity, 1e20, -62135596801, 253402300800, true, {}, "1",
    "1500-02-29T12:00:00Z", "2026-02-29T12:00:00Z", "2026-04-31T12:00:00Z", "0000-01-01T00:00:00Z",
    "2026-10-10", "2026-10-10T12:00:00", "2026-10-10T24:00:00Z",
    "2026-10-10T12:00:60Z", "2026-10-10T12:00:00+14:01",
    "2026-10-10T12:00:00-00:00", "2026-10-10T12:00:00+01:60",
    "2026-10-10T12:00:00.1234Z", " "];
  for (const [values, status] of [[valid, "valid"], [missing.map(value => [value, null]), "missing"], [invalid.map(value => [value, null]), "invalid"]]) {
    for (const [value, expected] of values) {
      const result = await inventoryRun([{ items: [{ ...item("dated"), create_time: value, update_time: value }], cursor: null }]);
      const entry = manifest(result).conversations[0];
      assert.equal(entry.create_time, expected, String(value));
      assert.equal(entry.update_time, expected);
      assert.equal(entry.create_time_status, status);
      assert.equal(entry.update_time_status, status);
      if (expected) assert.ok(result.downloads[1].text.includes('"' + expected + '"'));
      assert.ok(result.downloads[1].text.includes('"' + status + '"'));
    }
  }
});

test("session selection and invalid audit options still fail closed", async () => {
  for (const session of [{}, { accessToken: "synthetic" }, { accessToken: "synthetic", account: { id: {} } }]) {
    const result = await inventoryRun([], { session });
    assertRefused(result, /token|account ID/);
    assert.equal(result.requests.length, 1);
  }
  const invalid = await inventoryRun([], { fullAudit: "yes" });
  assertRefused(invalid, /boolean/);
  assert.equal(invalid.requests.length, 0);
});

test("Ruby consumes actual browser full, incremental and recovery checkpoints with identical timestamp evidence", async () => {
  const records = largeFixture();
  records[0].create_time = 1.125;
  records[0].title = 'Unicode café 😀 / "quoted"\nchat';
  records[0].extra_listing_metadata = { value: 1e-7, zero: -0 };
  const full = await baseline(records);
  const daily = manifest(await inventoryRun(listing(records), { previous: full, now: NEXT_DAY }));
  const audit = manifest(await inventoryRun(listing(records.filter(entry => entry.id !== "id-400")), {
    previous: daily, fullAudit: true, now: atOffset(2 * DAY)
  }));
  const program = [
    'require "./reconcile_exports"',
    'inventories = JSON.parse(STDIN.read)',
    'results = inventories.map { |inventory| ExportReconciler.allocate.send(:inventory_records, inventory) }',
    'puts JSON.generate(results)'
  ].join("\n");
  const child = spawnSync("ruby", ["-I.", "-e", program], {
    cwd: path.join(__dirname, ".."), input: JSON.stringify([full, daily, audit]), encoding: "utf8"
  });
  assert.equal(child.status, 0, child.stderr);
  const results = JSON.parse(child.stdout);
  assert.deepEqual(results.map(entries => entries.length), [500, 500, 500]);
  for (const entries of results) {
    assert.equal(entries.find(entry => entry.id === "id-0").create_time, "1970-01-01T00:00:01.125Z");
    assert.equal(entries.find(entry => entry.id === "id-0").title, records[0].title);
    assert.ok(entries.some(entry => entry.id === "id-400"));
  }
});
