"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../project_inventory.js"), "utf8");
const projectId = "g-p-test-project";
const item = id => ({ id, title: `Chat ${id}`, create_time: 1, update_time: 2 });

// Execute the unchanged browser program with synthetic session/page responses.
// Capture actual download payloads; no live account or network is used.
async function inventoryRun(pages, options = {}) {
  const requests = [];
  const downloads = [];
  const logs = [];
  const blobs = new Map();
  const window = {
    __chatProjectInventory: { stale: true },
    __adventureFinderProjectInventory: { stale: true },
    __chatProjectInventoryExpectedCount: options.expected
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
    atob,
    console: Object.fromEntries(["log", "error", "warn"].map(method =>
      [method, (...args) => logs.push(args)])),
    setTimeout: callback => { queueMicrotask(callback); return 1; },
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
        return { ok: true, json: async () => ({ accessToken: "synthetic", account: { id: "account-test" } }) };
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
    await vm.runInNewContext(source, sandbox, { timeout: 1000 });
  } catch (caught) {
    error = caught;
  }
  for (const download of downloads) download.text = await download.blob.text();
  return { error, requests, downloads, logs, window };
}

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
