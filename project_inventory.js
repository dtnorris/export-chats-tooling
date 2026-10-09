(async () => {
  "use strict";

  // Optional audit assertion; omit or clear it for an inventory of any size.
  const expectedCount = window.__chatProjectInventoryExpectedCount ?? null;
  const PAGE_LIMIT = 10000;
  const logPrefix = "[ChatGPT Project Inventory]";

  // Do not leave an earlier successful manifest visible after a failed rerun.
  delete window.__chatProjectInventory;
  delete window.__adventureFinderProjectInventory;

  const sleep = ms =>
    new Promise(resolve => setTimeout(resolve, ms));

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

  async function responseError(response) {
    const body =
      await response.text().catch(() => "");

    return (
      `${response.status} ${response.statusText}` +
      (body ? `\n${body}` : "")
    );
  }

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

    if (!accessToken) {
      fail(
        "Session response contained no access token."
      );
    }

    const accountId =
      getAccountId(session, accessToken);

    if (!accountId) {
      fail(
        "Could not determine ChatGPT account ID."
      );
    }

    return {
      accessToken,
      accountId
    };
  }

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

  const projectId =
    getProjectId();

  const {
    accessToken,
    accountId
  } = await getSessionContext();

  console.log(
    logPrefix,
    "Project:",
    projectId
  );

  const conversations = [];
  const rawPages = [];
  const seenIds = new Set();
  const seenCursors = new Set();

  let cursor = "0";
  let pageNumber = 0;

  while (true) {
    pageNumber++;

    if (pageNumber > PAGE_LIMIT) {
      fail(
        "Safety page limit reached before cursor exhaustion."
      );
    }

    if (seenCursors.has(cursor)) {
      fail(
        `Cursor cycle detected: ${cursor}`
      );
    }

    seenCursors.add(cursor);

    console.log(
      logPrefix,
      `Fetching project page ${pageNumber}; cursor=${cursor}`
    );

    const page =
      await fetchProjectPage({
        projectId,
        cursor,
        accessToken,
        accountId
      });

    rawPages.push(page);

    if (!page || typeof page !== "object" || !Array.isArray(page.items)) {
      fail(
        `Page ${pageNumber} did not contain an items array.`,
        page
      );
    }

    for (
      let index = 0;
      index < page.items.length;
      index++
    ) {
      const item =
        page.items[index];

      const id =
        item?.id;

      if (
        typeof id !== "string" ||
        !id.trim()
      ) {
        fail(
          `Page ${pageNumber}, item ${index} has no usable conversation ID.`,
          item
        );
      }

      if (seenIds.has(id)) {
        fail(
          `Duplicate conversation ID encountered: ${id}`
        );
      }

      seenIds.add(id);

      conversations.push({
        id,
        title:
          typeof item.title === "string"
            ? item.title
            : null,

        create_time:
          typeof item.create_time === "number"
            ? item.create_time
            : null,

        update_time:
          typeof item.update_time === "number"
            ? item.update_time
            : null
      });
    }

    const nextCursor =
      page.cursor ?? null;

    console.log(
      logPrefix,
      {
        page: pageNumber,
        pageItems: page.items.length,
        totalUnique: conversations.length,
        nextCursor
      }
    );

    if (
      page.items.length === 0 &&
      nextCursor !== null
    ) {
      fail(
        "Received an empty project page that still supplied another cursor."
      );
    }

    if (nextCursor === null) {
      break;
    }

    if (
      typeof nextCursor !== "string" ||
      !nextCursor.trim()
    ) {
      fail(
        "Project page returned an invalid next cursor.",
        nextCursor
      );
    }

    cursor =
      nextCursor;

    /*
     * This is deliberately gentle even though
     * these are lightweight list requests.
     */
    await sleep(1000);
  }

  if (expectedCount !== null && conversations.length !== expectedCount) {
    fail(`Inventory count mismatch: observed ${conversations.length}, expected ${expectedCount}. No inventory files were downloaded.`);
  }

  const inventory = {
    schema:
      "adventurefinder-chat-project-inventory/v0.1",

    generated_at:
      new Date().toISOString(),

    project_id:
      projectId,

    expected_conversation_count:
      expectedCount,

    observed_conversation_count:
      conversations.length,

    count_matches_expected:
      expectedCount === null ? null : conversations.length === expectedCount,

    page_count:
      rawPages.length,

    conversations,

    raw_pages:
      rawPages
  };

  window.__chatProjectInventory = inventory;
  // Compatibility alias for existing consumers of the v0.1 manifest.
  window.__adventureFinderProjectInventory = inventory;

  const date =
    localDateYYYYMMDD();

  const base =
    `${date} - ChatGPT ${safeFilenamePart(projectId).slice(0, 100)} Project Inventory`;

  downloadText(
    JSON.stringify(inventory, null, 2) + "\n",
    `${safeFilenamePart(base)}.json`,
    "application/json;charset=utf-8"
  );

  const csvLines = [
    [
      "id",
      "title",
      "create_time",
      "update_time"
    ].map(csvCell).join(","),

    ...conversations.map(
      c =>
        [
          c.id,
          c.title,
          c.create_time,
          c.update_time
        ]
          .map(csvCell)
          .join(",")
    )
  ];

  downloadText(
    csvLines.join("\n") + "\n",
    `${safeFilenamePart(base)}.csv`,
    "text/csv;charset=utf-8"
  );

  console.log(
    logPrefix,
    "========================================"
  );

  console.log(
    logPrefix,
    "INVENTORY COMPLETE"
  );

  console.log(
    logPrefix,
    "Pages:",
    rawPages.length
  );

  console.log(
    logPrefix,
    "Unique conversations:",
    conversations.length
  );

  console.log(
    logPrefix,
    "VALIDATION PASSED: pagination exhausted with unique conversation IDs.",
    expectedCount === null ? "No expected-count assertion configured." : `Expected count ${expectedCount} matched.`
  );

  console.log(
    logPrefix,
    "Manifest also available as window.__chatProjectInventory"
  );
})();
