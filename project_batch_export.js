(async () => {
  "use strict";

  const BASE_DELAY_MS = 60_000;
  const JITTER_MS = 10_000;
  const RATE_LIMIT_COOLDOWNS_MS = [
    180_000,
    300_000,
    600_000,
    1_200_000,
    1_800_000
  ];
  const SESSION_REFRESH_SKEW_SECONDS = 300;
  const logPrefix = "[ChatGPT Batch Export]";

  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  function fail(message, details) {
    if (details !== undefined) {
      console.error(logPrefix, message, details);
    } else {
      console.error(logPrefix, message);
    }
    throw new Error(message);
  }

  function currentProjectId() {
    const parts = new URL(location.href).pathname.split("/").filter(Boolean);
    const id = parts.find(part => part.startsWith("g-p-")) || null;
    if (!id) {
      fail("Run this from the open ChatGPT project page for this queue; no g-p-... project ID was found in the current URL.");
    }
    return id;
  }

  function decodeJwtPayload(token) {
    const pieces = token.split(".");
    if (pieces.length !== 3) return null;

    try {
      const base64 = pieces[1]
        .replace(/-/g, "+")
        .replace(/_/g, "/")
        .padEnd(Math.ceil(pieces[1].length / 4) * 4, "=");
      const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch {
      return null;
    }
  }

  function accountIdFromSession(session, accessToken) {
    const explicit =
      session.account?.id ??
      session.accountId ??
      session.user?.account_id ??
      session.user?.accountId;
    if (explicit) return explicit;

    const claims = decodeJwtPayload(accessToken);
    return (
      claims?.["https://api.openai.com/auth"]?.chatgpt_account_id ??
      claims?.chatgpt_account_id ??
      null
    );
  }

  async function responseText(response) {
    return await response.text().catch(() => "");
  }

  let sessionContext = null;

  async function refreshSession() {
    const response = await fetch("/api/auth/session", {
      credentials: "include",
      cache: "no-store"
    });
    if (!response.ok) {
      fail(`Could not read ChatGPT session: ${response.status} ${response.statusText}`);
    }

    const session = await response.json();
    const accessToken = session.accessToken;
    if (!accessToken) fail("ChatGPT session response contained no access token.");

    const accountId = accountIdFromSession(session, accessToken);
    if (!accountId) fail("Could not determine ChatGPT account ID.");

    const claims = decodeJwtPayload(accessToken);
    sessionContext = {
      accessToken,
      accountId,
      exp: typeof claims?.exp === "number" ? claims.exp : null
    };
    return sessionContext;
  }

  async function ensureSession() {
    const now = Math.floor(Date.now() / 1000);
    if (
      !sessionContext ||
      (sessionContext.exp && sessionContext.exp - now < SESSION_REFRESH_SKEW_SECONDS)
    ) {
      await refreshSession();
    }
    return sessionContext;
  }

  async function fetchConversation(conversationId, projectId) {
    const { accessToken, accountId } = await ensureSession();
    const endpoint = `/backend-api/conversation/${encodeURIComponent(conversationId)}`;
    const headers = {
      Accept: "application/json",
      Authorization: `Bearer ${accessToken}`,
      "ChatGPT-Account-ID": accountId,
      "chatgpt-project-id": projectId,
      "X-OpenAI-Target-Path": endpoint,
      "X-OpenAI-Target-Route": "/backend-api/conversation/{conversation_id}"
    };

    return await fetch(endpoint, {
      method: "GET",
      credentials: "include",
      cache: "no-store",
      headers
    });
  }

  function activeBranch(conversation) {
    const mapping = conversation?.mapping;
    let nodeId = conversation?.current_node;

    if (!mapping || typeof mapping !== "object") {
      throw new Error("Conversation payload has no mapping.");
    }
    if (!nodeId || !mapping[nodeId]) {
      throw new Error("Conversation payload has no valid current_node.");
    }

    const reversed = [];
    const seen = new Set();
    while (nodeId) {
      if (seen.has(nodeId)) {
        throw new Error("Cycle detected while following the active conversation branch.");
      }
      seen.add(nodeId);
      const node = mapping[nodeId];
      if (!node) throw new Error(`Missing conversation node: ${nodeId}`);
      reversed.push(node);
      nodeId = node.parent || null;
    }
    return reversed.reverse();
  }

  function isVisibleChatMessage(message) {
    if (!message?.author || !message?.content) return false;
    const role = message.author.role;
    if (role !== "user" && role !== "assistant") return false;
    if (message.metadata?.is_visually_hidden_from_conversation) return false;
    if (message.metadata?.is_thinking_preamble_message) return false;

    const type = message.content.content_type;
    if (type === "thoughts" || type === "reasoning_recap") return false;
    if (role === "assistant" && message.recipient && message.recipient !== "all") return false;
    return true;
  }

  function attachmentLines(message) {
    const attachments = message.metadata?.attachments;
    if (!Array.isArray(attachments)) return [];
    return attachments
      .map(a => a?.name || a?.file_name || null)
      .filter(Boolean)
      .map(name => `[Attachment: ${name}]`);
  }

  function extractPartText(part) {
    if (typeof part === "string") return part;
    if (!part || typeof part !== "object") return "";
    if (part.content_type === "audio_transcription" && typeof part.text === "string") return part.text;
    if (typeof part.text === "string") return part.text;
    if (part.content_type === "image_asset_pointer") return "[Image]";
    if (part.content_type === "audio_asset_pointer") return "[Audio]";
    if (part.content_type === "real_time_user_audio_video_asset_pointer") return "[Audio/Video]";
    return "";
  }

  function extractMessageText(message) {
    const content = message.content;
    const type = content.content_type;

    if (type === "text" || type === "multimodal_text") {
      const parts = Array.isArray(content.parts) ? content.parts : [];
      const text = parts.map(extractPartText).filter(Boolean).join("\n");
      return [text, ...attachmentLines(message)].filter(Boolean).join("\n\n").trim();
    }

    if (type === "code") {
      const language = typeof content.language === "string" ? content.language : "";
      const body = typeof content.text === "string" ? content.text : "";
      return `\`\`\`${language}\n${body}\n\`\`\``.trim();
    }

    if (typeof content.text === "string" && content.text.trim()) {
      return content.text.trim();
    }

    return null;
  }

  function renderConversation(conversation) {
    const branch = activeBranch(conversation);
    const exported = [];
    const unsupported = [];

    for (const node of branch) {
      const message = node.message;
      if (!isVisibleChatMessage(message)) continue;
      const text = extractMessageText(message);
      if (text === null) {
        unsupported.push({
          nodeId: node.id,
          role: message.author?.role,
          contentType: message.content?.content_type
        });
        continue;
      }
      if (!text.trim()) continue;
      exported.push({ role: message.author.role, text: text.trim() });
    }

    if (unsupported.length) {
      const error = new Error("Unsupported visible user/assistant message types; refusing to omit them.");
      error.exportDetails = unsupported;
      throw error;
    }
    if (!exported.length) {
      throw new Error("No visible user/assistant messages were found on the active branch.");
    }

    const markdown = exported.map((message, index) => {
      const label = message.role === "user" ? "User" : "Assistant";
      return `## Message ${index + 1}\n\n### ${label}\n\n${message.text}`;
    }).join("\n\n---\n\n") + "\n";

    return { markdown, messageCount: exported.length };
  }

  function conversationCreateDate(conversation, queueEntry) {
    const values = [conversation?.create_time, queueEntry?.create_time];
    for (const value of values) {
      if (typeof value === "number" && Number.isFinite(value)) {
        const date = new Date(value * 1000);
        if (!Number.isNaN(date.getTime())) return localDate(date);
      }
      if (typeof value === "string" && value) {
        const date = new Date(value);
        if (!Number.isNaN(date.getTime())) return localDate(date);
      }
    }
    return localDate(new Date());
  }

  function localDate(date) {
    const y = String(date.getFullYear()).padStart(4, "0");
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
  }

  function baseDelay() {
    const jitter = (Math.random() * 2 - 1) * JITTER_MS;
    return Math.max(10_000, Math.round(BASE_DELAY_MS + jitter));
  }

  function retryAfterMs(response) {
    const value = response.headers.get("Retry-After");
    if (!value) return 0;
    if (/^\d+$/.test(value)) return Number(value) * 1000;
    const at = Date.parse(value);
    return Number.isNaN(at) ? 0 : Math.max(0, at - Date.now());
  }

  function downloadCapture(payload) {
    const body = JSON.stringify(payload);
    const blob = new Blob([body], { type: "application/json;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    const stamp = Date.now();

    a.href = url;
    a.download = `AFCHAT_${payload.conversation_id}_${stamp}.json`;
    a.style.display = "none";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 30_000);
  }

  const queue = window.__adventureFinderBatchQueue;
  if (!queue || !Array.isArray(queue.pending)) {
    fail(
      "No embedded batch queue was found. Run ruby reconcile_exports.rb, then paste .state/project_batch_console.js into this console."
    );
  }

  const projectId = currentProjectId();
  if (queue.project_id !== projectId) {
    fail("Embedded queue belongs to a different ChatGPT project.", {
      currentProjectId: projectId,
      queueProjectId: queue.project_id
    });
  }

  if (window.__chatProjectBatchRunning) {
    fail("A batch runner is already active in this page.");
  }

  const requestedLimit = Number(window.__chatProjectBatchLimit);
  const runLimit = Number.isInteger(requestedLimit) && requestedLimit > 0
    ? Math.min(requestedLimit, queue.pending.length)
    : queue.pending.length;

  window.__chatProjectBatchRunning = true;
  window.__chatProjectBatchStop = false;
  window.__chatProjectBatchState = {
    startedAt: new Date().toISOString(),
    projectId,
    originalPending: queue.pending.length,
    runLimit,
    downloadsTriggeredThisRun: 0,
    extractionFailures: 0,
    current: null
  };

  console.log(logPrefix, {
    projectId,
    inventoryCount: queue.inventory_count,
    pendingInQueue: queue.pending.length,
    runLimit,
    baseDelaySeconds: BASE_DELAY_MS / 1000,
    stopCommand: "window.__chatProjectBatchStop = true",
    note: "Each success downloads one AFCHAT_*.json package for capture_watch.rb to ingest."
  });

  let rateLimitLevel = 0;

  try {
    for (let index = 0; index < runLimit; index++) {
      if (window.__chatProjectBatchStop) {
        console.warn(logPrefix, "Stop requested; exiting before the next conversation.");
        break;
      }

      const entry = queue.pending[index];
      window.__chatProjectBatchState.current = entry;
      console.log(logPrefix, `[${index + 1}/${runLimit}] ${entry.title || "(untitled)"} ${entry.id}`);

      let response;
      while (true) {
        response = await fetchConversation(entry.id, projectId);
        if (response.status !== 429) break;

        const scheduled = RATE_LIMIT_COOLDOWNS_MS[Math.min(rateLimitLevel, RATE_LIMIT_COOLDOWNS_MS.length - 1)];
        const cooldown = Math.max(scheduled, retryAfterMs(response));
        rateLimitLevel = Math.min(rateLimitLevel + 1, RATE_LIMIT_COOLDOWNS_MS.length - 1);
        console.warn(logPrefix, `HTTP 429 for ${entry.id}; pausing ${Math.ceil(cooldown / 1000)} seconds before retrying the same conversation.`);
        await sleep(cooldown);
        if (window.__chatProjectBatchStop) break;
      }

      if (window.__chatProjectBatchStop) break;

      if (!response.ok) {
        const body = await responseText(response);
        fail(`Conversation fetch failed with HTTP ${response.status}; stopping rather than broad-retrying.`, {
          conversationId: entry.id,
          status: response.status,
          body: body.slice(0, 4000)
        });
      }

      const conversation = await response.json();
      let rendered;
      try {
        rendered = renderConversation(conversation);
      } catch (error) {
        console.error(logPrefix, `Validation failed for ${entry.id}; leaving it pending and continuing.`, error);
        window.__chatProjectBatchState.extractionFailures++;
        await sleep(baseDelay());
        continue;
      }

      downloadCapture({
        schema: "adventurefinder-chat-download-capture/v0.1",
        project_id: projectId,
        conversation_id: entry.id,
        title: conversation.title || entry.title || "Chat Export",
        create_date: conversationCreateDate(conversation, entry),
        message_count: rendered.messageCount,
        captured_at: new Date().toISOString(),
        markdown: rendered.markdown,
        raw: conversation
      });

      window.__chatProjectBatchState.downloadsTriggeredThisRun++;
      rateLimitLevel = Math.max(0, rateLimitLevel - 1);
      console.log(
        logPrefix,
        `Triggered capture download for ${entry.id}. ` +
        "capture_watch.rb is authoritative for whether it was safely ingested."
      );

      if (index < runLimit - 1 && !window.__chatProjectBatchStop) {
        await sleep(baseDelay());
      }
    }
  } finally {
    window.__chatProjectBatchState.finishedAt = new Date().toISOString();
    window.__chatProjectBatchState.current = null;
    window.__chatProjectBatchRunning = false;
    console.log(logPrefix, "Batch runner finished/stopped.", window.__chatProjectBatchState);
  }
})();
