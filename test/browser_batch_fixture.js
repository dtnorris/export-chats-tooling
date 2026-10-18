"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { webcrypto } = require("node:crypto");

/** Execute the real batch program in a synthetic authenticated browser. Inputs
 * supply a queue, raw responses and optional HTTP/stop fixtures; returns actual
 * downloads, request order and waits. Never performs network or real-time sleeps.
 */
async function batchRun(queue, conversations, options = {}) {
  const requests = [];
  const downloads = [];
  const delays = [];
  const blobs = new Map();
  const window = { __adventureFinderBatchQueue: queue, __chatProjectBatchLimit: options.limit };
  let index = 0;
  class FixtureDate extends Date {
    constructor(...args) { super(...(args.length ? args : [options.now || "2026-10-12T12:00:00.000Z"])); }
    static now() { return new FixtureDate().getTime(); }
  }
  class BrowserURL extends URL {
    static createObjectURL(blob) { const url = `blob:${blobs.size}`; blobs.set(url, blob); return url; }
    static revokeObjectURL() {}
  }
  const sandbox = {
    window, URL: BrowserURL, Blob, TextDecoder, TextEncoder, crypto: webcrypto, atob, Date: FixtureDate,
    Math: Object.assign(Object.create(Math), { random: () => 0.5 }),
    location: { href: `https://chatgpt.com/${options.project || queue.project_id}/project` },
    console: { log() {}, warn() {}, error() {} },
    setTimeout(callback, milliseconds) {
      delays.push(milliseconds);
      if (options.stopOnWait && milliseconds >= options.stopOnWait) window.__chatProjectBatchStop = true;
      queueMicrotask(callback);
    },
    document: {
      body: { appendChild() {} },
      createElement: () => ({ style: {}, remove() {}, click() {
        downloads.push({ name: this.download, blob: blobs.get(this.href) });
        if (options.stopAfterDownload) window.__chatProjectBatchStop = true;
      } })
    },
    async fetch(url, init) {
      requests.push({ url, headers: init.headers });
      if (url === "/api/auth/session") return { ok: true, json: async () => ({ accessToken: "synthetic", account: { id: options.account || queue.account_id } }) };
      const response = conversations[index++];
      if (response === undefined) throw new Error("Unexpected conversation request");
      const status = response.status || 200;
      return { ok: status === 200, status, statusText: "Synthetic", headers: { get: () => response.retryAfter || null },
        text: async () => typeof response === "string" ? response : JSON.stringify(response.raw || response) };
    }
  };
  let error;
  try {
    await vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../project_batch_export.js"), "utf8"), sandbox, { timeout: 1000 });
  } catch (caught) { error = caught.message; }
  for (const download of downloads) { download.text = await download.blob.text(); delete download.blob; }
  return { error, requests, downloads, delays, state: window.__chatProjectBatchState, running: window.__chatProjectBatchRunning };
}

module.exports = { batchRun };

if (require.main === module) {
  const input = JSON.parse(fs.readFileSync(0, "utf8"));
  batchRun(input.queue, input.conversations, input.options).then(result => process.stdout.write(JSON.stringify(result)));
}
