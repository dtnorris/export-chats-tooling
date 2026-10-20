(async () => {
  "use strict";

  // Optional audit assertion; omit or clear it for an inventory of any size.
  const expectedCount = window.__chatProjectInventoryExpectedCount ?? null;
  const PAGE_LIMIT = 10000;
  const DAILY_PAGE_LIMIT = 100;
  const OVERLAP_MS = 7 * 86400000;
  const AUDIT_INTERVAL_MS = 7 * 86400000;
  const SCHEMA = "adventurefinder-chat-project-inventory/v0.2";
  const PRODUCER = "project_inventory.js/ECT-01";
  const previous = window.__chatProjectInventoryPrevious ?? null;
  const forceAudit = window.__chatProjectInventoryFullAudit ?? false;
  const startedAt = new Date().toISOString();
  const logPrefix = "[ChatGPT Project Inventory]";

  // Do not leave an earlier successful manifest visible after a failed rerun.
  delete window.__chatProjectInventory;
  delete window.__adventureFinderProjectInventory;

  /** Wait milliseconds between sequential requests; resolves without a value. */
  const sleep = ms =>
    new Promise(resolve => setTimeout(resolve, ms));

  /** Log a non-secret validation message and throw Error; never publish on failure. */
  function fail(message, details) {
    if (details !== undefined) {
      console.error(logPrefix, message, details);
    } else {
      console.error(logPrefix, message);
    }

    throw new Error(message);
  }

  if (expectedCount !== null &&
      (!Number.isSafeInteger(expectedCount) || expectedCount < 0)) {
    fail("window.__chatProjectInventoryExpectedCount must be a non-negative safe integer, or null/undefined to disable the count check.");
  }

  /** Read the open project URL; return its ID or throw Error outside a project. */
  function getProjectId() {
    const parts = new URL(location.href)
      .pathname
      .split("/")
      .filter(Boolean);

    const projectId =
      parts.find(part => part.startsWith("g-p-")) || null;

    if (!projectId) {
      fail(
        "Could not find a g-p-... project ID in the current URL. " +
        "Run this from the open ChatGPT project page you want to inventory."
      );
    }

    return projectId;
  }

  /** Decode session JWT claims for account selection; return null on invalid input. */
  function decodeJwtPayload(token) {
    const pieces = token.split(".");

    if (pieces.length !== 3) {
      return null;
    }

    try {
      const base64 = pieces[1]
        .replace(/-/g, "+")
        .replace(/_/g, "/")
        .padEnd(
          Math.ceil(pieces[1].length / 4) * 4,
          "="
        );

      const bytes = Uint8Array.from(
        atob(base64),
        c => c.charCodeAt(0)
      );

      return JSON.parse(
        new TextDecoder().decode(bytes)
      );
    } catch {
      return null;
    }
  }

  /** Return the selected non-secret account ID from session/claims, or null. */
  function getAccountId(session, accessToken) {
    const explicit =
      session.account?.id ??
      session.accountId ??
      session.user?.account_id ??
      session.user?.accountId;

    if (explicit) {
      return explicit;
    }

    const claims =
      decodeJwtPayload(accessToken);

    return (
      claims?.[
        "https://api.openai.com/auth"
      ]?.chatgpt_account_id ??
      claims?.chatgpt_account_id ??
      null
    );
  }

  /** Return HTTP status only: response bodies can contain private session details. */
  async function responseError(response) {
    return response.status + " " + response.statusText;
  }

  /** Read browser authentication; return token/account or throw on missing identity/HTTP errors. */
  async function getSessionContext() {
    const response =
      await fetch("/api/auth/session", {
        credentials: "include",
        cache: "no-store"
      });

    if (!response.ok) {
      fail(
        "Could not read ChatGPT session: " +
        await responseError(response)
      );
    }

    const session =
      await response.json();

    const accessToken =
      session.accessToken;

    if (typeof accessToken !== "string" || !accessToken) {
      fail(
        "Session response contained no access token."
      );
    }

    const accountId =
      getAccountId(session, accessToken);

    if (typeof accountId !== "string" || !accountId.trim()) {
      fail(
        "Could not determine ChatGPT account ID."
      );
    }

    return {
      accessToken,
      accountId
    };
  }

  /** Fetch one cursor using the existing session; return JSON or throw, including on 429. */
  async function fetchProjectPage({
    projectId,
    cursor,
    accessToken,
    accountId
  }) {
    const query =
      new URLSearchParams({
        cursor
      });

    const endpoint =
      `/backend-api/gizmos/` +
      `${encodeURIComponent(projectId)}` +
      `/conversations?${query}`;

    const headers = {
      Accept: "application/json",

      Authorization:
        `Bearer ${accessToken}`,

      "ChatGPT-Account-ID":
        accountId,

      "chatgpt-project-id":
        projectId,

      "X-OpenAI-Target-Path":
        endpoint,

      "X-OpenAI-Target-Route":
        "/backend-api/gizmos/{gizmo_id}/conversations"
    };

    const response =
      await fetch(endpoint, {
        method: "GET",
        credentials: "include",
        cache: "no-store",
        headers
      });

    if (!response.ok) {
      fail(
        `Project conversation page failed at cursor ${cursor}: ` +
        await responseError(response)
      );
    }

    return await response.json();
  }

  /** Return a bounded filename component for an arbitrary label; does not throw. */
  function safeFilenamePart(value) {
    return String(value || "project")
      .replace(
        /[<>:"/\\|?*\u0000-\u001f]/g,
        "-"
      )
      .replace(/\s+/g, " ")
      .trim()
      .replace(/[. ]+$/g, "")
      .slice(0, 180);
  }

  /** Format a Date as a local filename date; expects a valid Date. */
  function localDateYYYYMMDD(
    date = new Date()
  ) {
    const y =
      String(date.getFullYear())
        .padStart(4, "0");

    const m =
      String(date.getMonth() + 1)
        .padStart(2, "0");

    const d =
      String(date.getDate())
        .padStart(2, "0");

    return `${y}-${m}-${d}`;
  }

  /** Trigger a text download; browser/DOM failures propagate to the caller. */
  function downloadText(
    text,
    filename,
    mime
  ) {
    const blob =
      new Blob(
        [text],
        { type: mime }
      );

    const url =
      URL.createObjectURL(blob);

    const a =
      document.createElement("a");

    a.href = url;
    a.download = filename;
    a.style.display = "none";

    document.body.appendChild(a);
    a.click();
    a.remove();

    setTimeout(
      () => URL.revokeObjectURL(url),
      10000
    );
  }

  /** Encode a nullable value as a quoted CSV cell; returns text. */
  function csvCell(value) {
    if (
      value === null ||
      value === undefined
    ) {
      return "";
    }

    return (
      `"${String(value)
        .replace(/"/g, '""')}"`
    );
  }

  /**
   * Normalize epoch seconds or strict zoned ISO timestamps to millisecond UTC.
   * Returns {value, status}; missing/invalid evidence remain distinct, never throw.
   * Supports years 0001..9999, offsets through ±14:00, no leap seconds or -00:00.
   */
  function timestamp(value) {
    if (value === null || value === undefined || value === "") return { value: null, status: "missing" };
    let milliseconds;
    if (typeof value === "number" && Number.isFinite(value)) {
      milliseconds = Math.round(value * 1000);
    } else if (typeof value === "string") {
      const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
      if (!match) return { value: null, status: "invalid" };
      const [, year, month, day, hour, minute, second, , zone] = match;
      const offsetHour = zone === "Z" ? 0 : Number(zone.slice(1, 3));
      const offsetMinute = zone === "Z" ? 0 : Number(zone.slice(4, 6));
      const calendar = new Date(0);
      calendar.setUTCFullYear(Number(year), Number(month) - 1, Number(day));
      if (Number(year) < 1 || calendar.getUTCFullYear() !== Number(year) ||
          calendar.getUTCMonth() !== Number(month) - 1 || calendar.getUTCDate() !== Number(day) ||
          Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59 ||
          offsetHour > 14 || offsetMinute > 59 || (offsetHour === 14 && offsetMinute !== 0) || zone === "-00:00") {
        return { value: null, status: "invalid" };
      }
      milliseconds = Date.parse(value);
    }
    if (!Number.isFinite(milliseconds) || milliseconds < -62135596800000 || milliseconds > 253402300799999) {
      return { value: null, status: "invalid" };
    }
    return { value: new Date(milliseconds).toISOString(), status: "valid" };
  }

  /** Normalize a listing item; return a record or throw for missing identity. */
  function record(item) {
    if (!item || typeof item.id !== "string" || !item.id.trim()) fail("Listing item has no usable conversation ID.");
    const created = timestamp(item.create_time);
    const updated = timestamp(item.update_time);
    return {
      id: item.id,
      title: typeof item.title === "string" ? item.title : null,
      create_time: created.value,
      create_time_status: created.status,
      update_time: updated.value,
      update_time_status: updated.status
    };
  }

  /**
   * Encode JSON values with type tags and IEEE-754 numbers for cross-language hashing.
   * Returns text, preserving object order; undefined object fields are omitted like JSON.
   * Non-finite numbers become null like JSON serialization; accepts JSON-shaped input.
   */
  function checkpointEncoding(value) {
    if (value === null || value === undefined || (typeof value === "number" && !Number.isFinite(value))) return "n";
    if (typeof value === "boolean") return value ? "b1" : "b0";
    if (typeof value === "string") return "s" + JSON.stringify(value);
    if (typeof value === "number") {
      const bytes = new Uint8Array(8);
      new DataView(bytes.buffer).setFloat64(0, value === 0 ? 0 : value);
      return "d" + Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    }
    if (Array.isArray(value)) return "[" + value.map(checkpointEncoding).join(",") + "]";
    return "{" + Object.keys(value).filter(key => value[key] !== undefined)
      .map(key => JSON.stringify(key) + ":" + checkpointEncoding(value[key])).join(",") + "}";
  }

  /** Hash the typed checkpoint encoding excluding its checksum; return SHA-256 hex. */
  async function checksum(inventory) {
    const { checkpoint_sha256, ...payload } = inventory;
    const bytes = new TextEncoder().encode(checkpointEncoding(payload));
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  }

  /**
   * Validate an unedited producer checkpoint against this session before listing.
   * Return it or throw; corrupt/mismatched input is never silently reset or merged.
   * Checksums detect corruption, not maliciously re-signed files or server omissions.
   */
  async function validatePrevious(inventory, projectId, accountId) {
    if (!inventory || inventory.schema !== SCHEMA || inventory.producer !== PRODUCER ||
        inventory.project_id !== projectId || inventory.account_id !== accountId) {
      fail("Previous inventory schema, provenance, project or account mismatch; retain it and establish a matching full baseline.");
    }
    if (!/^[0-9a-f]{64}$/.test(inventory.checkpoint_sha256) ||
        await checksum(inventory) !== inventory.checkpoint_sha256) fail("Previous inventory checkpoint checksum mismatch.");
    const audit = inventory.full_audit;
    const scanTime = timestamp(inventory.scan_started_at).value;
    const auditTime = timestamp(audit?.started_at).value;
    if (!scanTime || !auditTime || scanTime !== inventory.scan_started_at || auditTime !== audit.started_at ||
        auditTime > scanTime || scanTime > startedAt || inventory.watermark !== scanTime ||
        !["exhaustive", "incremental"].includes(inventory.coverage) ||
        audit.id !== auditTime || !Number.isSafeInteger(audit.observed_count) || audit.observed_count < 0 ||
        !Number.isSafeInteger(audit.page_count) || audit.page_count < 1 || audit.page_count > PAGE_LIMIT ||
        typeof audit.ordered !== "boolean" || typeof audit.timestamps_usable !== "boolean" ||
        !Array.isArray(inventory.conversations) || !Array.isArray(inventory.raw_pages) ||
        inventory.page_count !== inventory.raw_pages.length || inventory.page_count < 1 || inventory.page_count > PAGE_LIMIT ||
        inventory.known_conversation_count !== inventory.conversations.length ||
        inventory.overlap_ms !== OVERLAP_MS || inventory.audit_interval_ms !== AUDIT_INTERVAL_MS) {
      fail("Previous inventory has invalid checkpoint or full-audit metadata.");
    }
    const ids = new Map();
    let currentCount = 0;
    let auditCount = 0;
    for (const entry of inventory.conversations) {
      const normalized = record(entry);
      if (ids.has(entry.id) || ![true, false].includes(entry.observed_in_scan) ||
          !timestamp(entry.last_observed_at).value || entry.last_observed_at > scanTime ||
          (entry.last_full_audit_at !== null && (!timestamp(entry.last_full_audit_at).value || entry.last_full_audit_at > auditTime))) {
        fail("Previous inventory has duplicate IDs or invalid observation provenance.");
      }
      for (const field of ["create_time", "update_time"]) {
        if (!["valid", "missing", "invalid"].includes(entry[field + "_status"]) ||
            normalized[field] !== entry[field] ||
            (entry[field] !== null) !== (entry[field + "_status"] === "valid")) fail("Previous inventory has invalid normalized timestamps.");
      }
      ids.set(entry.id, entry);
      if (entry.observed_in_scan) {
        currentCount++;
        if (entry.last_observed_at !== scanTime) fail("Previous inventory has inconsistent scan observations.");
      }
      if (entry.last_full_audit_at === auditTime) auditCount++;
    }
    const rawIds = new Set();
    let ordered = true;
    let usable = true;
    let lastUpdate = null;
    const cursors = new Set(["0"]);
    for (const [index, page] of inventory.raw_pages.entries()) {
      if (!page || !Array.isArray(page.items)) fail("Previous inventory has malformed raw pages.");
      const next = page.cursor ?? null;
      if (next !== null && (typeof next !== "string" || !next.trim() || cursors.has(next))) fail("Previous inventory has invalid cursors.");
      if (next !== null) cursors.add(next);
      if ((index < inventory.raw_pages.length - 1 && next === null) ||
          (page.items.length === 0 && next !== null)) fail("Previous inventory has inconsistent page coverage.");
      for (const item of page.items) {
        const normalized = record(item);
        if (rawIds.has(item.id) || !ids.has(item.id)) fail("Previous inventory has duplicate or unknown raw IDs.");
        rawIds.add(item.id);
        if (normalized.update_time === null) usable = false;
        if (lastUpdate !== null && normalized.update_time !== null && normalized.update_time > lastUpdate) ordered = false;
        lastUpdate = normalized.update_time;
        const entry = ids.get(item.id);
        if (!entry.observed_in_scan || ["title", "create_time", "update_time", "create_time_status", "update_time_status"].some(field => normalized[field] !== entry[field])) {
          fail("Previous inventory raw pages disagree with cumulative observations.");
        }
      }
    }
    if (currentCount !== inventory.observed_conversation_count || rawIds.size !== currentCount || auditCount !== audit.observed_count ||
        (inventory.coverage === "exhaustive" && (inventory.raw_pages.at(-1).cursor != null || auditTime !== scanTime || currentCount !== auditCount)) ||
        (inventory.coverage === "incremental" && inventory.raw_pages.at(-1).cursor == null)) {
      fail("Previous inventory has inconsistent observation counts or coverage.");
    }
    if (inventory.coverage === "exhaustive" &&
        (audit.page_count !== inventory.page_count || audit.ordered !== ordered || audit.timestamps_usable !== usable)) {
      fail("Previous inventory full-audit proof disagrees with raw pages.");
    }
    if (inventory.coverage === "incremental" &&
        (!ordered || !usable || !audit.ordered || !audit.timestamps_usable ||
         Date.parse(scanTime) - Date.parse(auditTime) >= AUDIT_INTERVAL_MS ||
         timestamp(inventory.cutoff).value !== inventory.cutoff || lastUpdate >= inventory.cutoff ||
         inventory.page_count >= DAILY_PAGE_LIMIT)) {
      fail("Previous inventory has unsafe incremental stopping evidence.");
    }
    return inventory;
  }

  if (typeof forceAudit !== "boolean") fail("Full-audit option must be boolean.");
  const projectId = getProjectId();
  const { accessToken, accountId } = await getSessionContext();
  if (previous !== null) await validatePrevious(previous, projectId, accountId);

  let reason = !previous ? "initial" : forceAudit ? "forced" : expectedCount !== null ? "expected-count-audit" :
    Date.parse(startedAt) - Date.parse(previous.full_audit.started_at) >= AUDIT_INTERVAL_MS ? "audit-due" :
    !previous.full_audit.timestamps_usable || !previous.full_audit.ordered ? "unusable-baseline-timestamps-or-order" : "daily";
  let incremental = reason === "daily";
  const cutoff = incremental ? new Date(Date.parse(previous.watermark) - OVERLAP_MS).toISOString() : null;
  const conversations = [];
  const rawPages = [];
  const seenIds = new Set();
  const seenCursors = new Set();
  let cursor = "0";
  let lastUpdate = null;
  let ordered = true;
  let timestampsUsable = true;
  let exhausted = false;

  while (true) {
    if (rawPages.length >= PAGE_LIMIT) fail("Safety page limit reached before cursor exhaustion.");
    if (seenCursors.has(cursor)) fail("Cursor cycle detected: " + cursor);
    seenCursors.add(cursor);
    console.log(logPrefix, "Fetching project page " + (rawPages.length + 1) + "; cursor=" + cursor);
    const page = await fetchProjectPage({ projectId, cursor, accessToken, accountId });
    if (!page || !Array.isArray(page.items)) fail("Project page did not contain an items array.");
    rawPages.push(page);
    for (const item of page.items) {
      const entry = record(item);
      if (seenIds.has(entry.id)) fail("Duplicate conversation ID encountered: " + entry.id);
      seenIds.add(entry.id);
      conversations.push(entry);
      if (entry.update_time === null) timestampsUsable = false;
      if (entry.update_time !== null && lastUpdate !== null && entry.update_time > lastUpdate) ordered = false;
      lastUpdate = entry.update_time;
    }
    const nextCursor = page.cursor ?? null;
    if (page.items.length === 0 && nextCursor !== null) fail("Received an empty project page that still supplied another cursor.");
    if (nextCursor !== null && (typeof nextCursor !== "string" || !nextCursor.trim())) fail("Project page returned an invalid next cursor.");
    if (nextCursor !== null && seenCursors.has(nextCursor)) fail("Cursor cycle detected: " + nextCursor);

    // Continue the same validated traversal to exhaustion when stopping becomes unsafe.
    if (incremental && (!timestampsUsable || !ordered || rawPages.length >= DAILY_PAGE_LIMIT)) {
      incremental = false;
      reason = !timestampsUsable ? "unusable-update-time-fallback" : !ordered ? "ordering-fallback" : "daily-page-bound-fallback";
    }
    if (nextCursor === null) {
      exhausted = true;
      break;
    }
    // Strictly older: all cutoff ties are included, and the entire page is validated.
    if (incremental && lastUpdate !== null && lastUpdate < cutoff) break;
    cursor = nextCursor;
    await sleep(1000);
  }

  if (expectedCount !== null && conversations.length !== expectedCount) {
    fail("Inventory count mismatch: observed " + conversations.length + ", expected " + expectedCount + ". No inventory files were downloaded.");
  }
  const coverage = exhausted ? "exhaustive" : "incremental";
  const known = new Map((previous?.conversations ?? []).map(entry => [entry.id, { ...entry, observed_in_scan: false }]));
  for (const entry of conversations) {
    known.set(entry.id, {
      ...entry,
      observed_in_scan: true,
      last_observed_at: startedAt,
      last_full_audit_at: exhausted ? startedAt : known.get(entry.id)?.last_full_audit_at ?? null
    });
  }
  const inventory = {
    schema: SCHEMA,
    producer: PRODUCER,
    generated_at: new Date().toISOString(),
    scan_started_at: startedAt,
    project_id: projectId,
    account_id: accountId,
    coverage,
    scan_reason: reason,
    watermark: startedAt,
    overlap_ms: OVERLAP_MS,
    audit_interval_ms: AUDIT_INTERVAL_MS,
    cutoff,
    full_audit: exhausted ? {
      id: startedAt,
      started_at: startedAt,
      observed_count: conversations.length,
      page_count: rawPages.length,
      ordered,
      timestamps_usable: timestampsUsable
    } : previous.full_audit,
    expected_conversation_count: expectedCount,
    observed_conversation_count: conversations.length,
    known_conversation_count: known.size,
    count_matches_expected: expectedCount === null ? null : conversations.length === expectedCount,
    page_count: rawPages.length,
    conversations: Array.from(known.values()),
    raw_pages: rawPages
  };
  inventory.checkpoint_sha256 = await checksum(inventory);

  const date = localDateYYYYMMDD();
  const base = date + " - ChatGPT " + safeFilenamePart(projectId).slice(0, 100) + " Project Inventory";
  const columns = ["id", "title", "create_time", "update_time", "create_time_status", "update_time_status", "observed_in_scan", "last_observed_at", "last_full_audit_at"];
  const csvLines = [columns.map(csvCell).join(","), ...inventory.conversations.map(entry => columns.map(column => csvCell(entry[column])).join(","))];
  downloadText(JSON.stringify(inventory, null, 2) + "\n", safeFilenamePart(base) + ".json", "application/json;charset=utf-8");
  downloadText(csvLines.join("\n") + "\n", safeFilenamePart(base) + ".csv", "text/csv;charset=utf-8");
  window.__chatProjectInventory = inventory;
  window.__adventureFinderProjectInventory = inventory;
  window.__chatProjectInventoryPrevious = inventory;
  console.log(logPrefix, {
    coverage, reason, pages: rawPages.length, observed: conversations.length, known: known.size,
    note: exhausted ? "Cursor exhaustion; not an atomic snapshot or proof of server completeness." :
      "Conditional discovery only: assumes the unseen suffix is ordered and records become visible within overlap."
  });
})();
