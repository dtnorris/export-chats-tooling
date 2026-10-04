(async () => {
  "use strict";

  const logPrefix = "[ChatGPT Markdown Export]";

  function fail(message, details) {
    if (details !== undefined) {
      console.error(logPrefix, message, details);
    } else {
      console.error(logPrefix, message);
    }

    throw new Error(message);
  }

  function getConversationContext() {
    const url = new URL(location.href);
    const parts = url.pathname.split("/").filter(Boolean);
    const cIndex = parts.lastIndexOf("c");

    if (cIndex === -1 || !parts[cIndex + 1]) {
      fail(
        "This page URL does not look like an open ChatGPT conversation."
      );
    }

    const conversationId = parts[cIndex + 1];

    const projectId =
      parts
        .slice(0, cIndex)
        .find(part => part.startsWith("g-p-")) || null;

    return {
      conversationId,
      projectId
    };
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

    const claims = decodeJwtPayload(accessToken);

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

  async function fetchConversation() {
    const {
      conversationId,
      projectId
    } = getConversationContext();

    const sessionResponse =
      await fetch("/api/auth/session", {
        credentials: "include",
        cache: "no-store"
      });

    if (!sessionResponse.ok) {
      fail(
        "Could not read the current ChatGPT session: " +
        await responseError(sessionResponse)
      );
    }

    const session =
      await sessionResponse.json();

    const accessToken =
      session.accessToken;

    if (!accessToken) {
      fail(
        "The ChatGPT session response did not " +
        "contain an access token."
      );
    }

    const accountId =
      getAccountId(session, accessToken);

    if (!accountId) {
      fail(
        "Could not determine the current " +
        "ChatGPT account ID."
      );
    }

    const endpoint =
      `/backend-api/conversation/` +
      `${encodeURIComponent(conversationId)}`;

    const headers = {
      Accept: "application/json",

      Authorization:
        `Bearer ${accessToken}`,

      "ChatGPT-Account-ID":
        accountId,

      "X-OpenAI-Target-Path":
        endpoint,

      "X-OpenAI-Target-Route":
        "/backend-api/conversation/{conversation_id}"
    };

    if (projectId) {
      headers["chatgpt-project-id"] =
        projectId;
    }

    const response =
      await fetch(endpoint, {
        method: "GET",
        credentials: "include",
        cache: "no-store",
        headers
      });

    if (!response.ok) {
      fail(
        `Could not fetch conversation ` +
        `${conversationId}: ` +
        await responseError(response)
      );
    }

    return await response.json();
  }

  function activeBranch(conversation) {
    const mapping =
      conversation?.mapping;

    let nodeId =
      conversation?.current_node;

    if (
      !mapping ||
      typeof mapping !== "object"
    ) {
      fail(
        "Conversation payload has no mapping."
      );
    }

    if (
      !nodeId ||
      !mapping[nodeId]
    ) {
      fail(
        "Conversation payload has no valid current_node."
      );
    }

    const reversed = [];
    const seen = new Set();

    while (nodeId) {
      if (seen.has(nodeId)) {
        fail(
          "Cycle detected while following " +
          "the active conversation branch."
        );
      }

      seen.add(nodeId);

      const node =
        mapping[nodeId];

      if (!node) {
        fail(
          `Missing conversation node: ${nodeId}`
        );
      }

      reversed.push(node);

      nodeId =
        node.parent || null;
    }

    return reversed.reverse();
  }

  function isVisibleChatMessage(message) {
    if (
      !message?.author ||
      !message?.content
    ) {
      return false;
    }

    const role =
      message.author.role;

    if (
      role !== "user" &&
      role !== "assistant"
    ) {
      return false;
    }

    if (
      message.metadata
        ?.is_visually_hidden_from_conversation
    ) {
      return false;
    }

    if (
      message.metadata
        ?.is_thinking_preamble_message
    ) {
      return false;
    }

    const type =
      message.content.content_type;

    if (
      type === "thoughts" ||
      type === "reasoning_recap"
    ) {
      return false;
    }

    if (
      role === "assistant" &&
      message.recipient &&
      message.recipient !== "all"
    ) {
      return false;
    }

    return true;
  }

  function attachmentLines(message) {
    const attachments =
      message.metadata?.attachments;

    if (!Array.isArray(attachments)) {
      return [];
    }

    return attachments
      .map(
        a =>
          a?.name ||
          a?.file_name ||
          null
      )
      .filter(Boolean)
      .map(
        name =>
          `[Attachment: ${name}]`
      );
  }

  function extractPartText(part) {
    if (typeof part === "string") {
      return part;
    }

    if (
      !part ||
      typeof part !== "object"
    ) {
      return "";
    }

    if (
      part.content_type ===
        "audio_transcription" &&
      typeof part.text === "string"
    ) {
      return part.text;
    }

    if (
      typeof part.text === "string"
    ) {
      return part.text;
    }

    if (
      part.content_type ===
      "image_asset_pointer"
    ) {
      return "[Image]";
    }

    if (
      part.content_type ===
      "audio_asset_pointer"
    ) {
      return "[Audio]";
    }

    if (
      part.content_type ===
      "real_time_user_audio_video_asset_pointer"
    ) {
      return "[Audio/Video]";
    }

    return "";
  }

  function extractMessageText(message) {
    const content =
      message.content;

    const type =
      content.content_type;

    if (
      type === "text" ||
      type === "multimodal_text"
    ) {
      const parts =
        Array.isArray(content.parts)
          ? content.parts
          : [];

      const text =
        parts
          .map(extractPartText)
          .filter(Boolean)
          .join("\n");

      const attachments =
        attachmentLines(message);

      return [
        text,
        ...attachments
      ]
        .filter(Boolean)
        .join("\n\n")
        .trim();
    }

    if (type === "code") {
      const language =
        typeof content.language === "string"
          ? content.language
          : "";

      const body =
        typeof content.text === "string"
          ? content.text
          : "";

      return (
        `\`\`\`${language}\n` +
        `${body}\n` +
        `\`\`\``
      ).trim();
    }

    if (
      typeof content.text === "string" &&
      content.text.trim()
    ) {
      return content.text.trim();
    }

    return null;
  }

  function safeFilenamePart(value) {
    return String(
      value || "Chat Export"
    )
      .replace(
        /[<>:"/\\|?*\u0000-\u001f]/g,
        "-"
      )
      .replace(/\s+/g, " ")
      .trim()
      .replace(/[. ]+$/g, "")
      .slice(0, 180) ||
      "Chat Export";
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
      10_000
    );
  }

  console.log(
    logPrefix,
    "Fetching full conversation payload..."
  );

  const conversation =
    await fetchConversation();

  const branch =
    activeBranch(conversation);

  const exported = [];
  const unsupported = [];

  for (const node of branch) {
    const message =
      node.message;

    if (
      !isVisibleChatMessage(message)
    ) {
      continue;
    }

    const text =
      extractMessageText(message);

    if (text === null) {
      unsupported.push({
        nodeId: node.id,
        role:
          message.author?.role,
        contentType:
          message.content?.content_type
      });

      continue;
    }

    if (!text.trim()) {
      continue;
    }

    exported.push({
      role:
        message.author.role,
      text:
        text.trim()
    });
  }

  if (unsupported.length) {
    console.error(
      logPrefix,
      "Unsupported visible user/assistant message types:",
      unsupported
    );

    fail(
      "Export aborted rather than silently " +
      "omitting visible message content. " +
      "See the unsupported message list " +
      "in the console."
    );
  }

  if (!exported.length) {
    fail(
      "No visible user/assistant messages " +
      "were found on the active branch."
    );
  }

  const blocks =
    exported.map(
      (message, index) => {
        const label =
          message.role === "user"
            ? "User"
            : "Assistant";

        return (
          `## Message ${index + 1}\n\n` +
          `### ${label}\n\n` +
          `${message.text}`
        );
      }
    );

  const markdown =
    blocks.join("\n\n---\n\n") +
    "\n";

  const title =
    safeFilenamePart(
      conversation.title ||
      document.title ||
      "Chat Export"
    );

  const filename =
    `${localDateYYYYMMDD()} - ` +
    `${title}.md`;

  window.__chatConversationRaw =
    conversation;

  window.__chatExportMessages =
    exported;

  window.__chatExportMarkdown =
    markdown;

  console.log(
    logPrefix,
    {
      title:
        conversation.title,

      activeBranchNodes:
        branch.length,

      exportedVisibleMessages:
        exported.length,

      markdownCharacters:
        markdown.length,

      filename
    }
  );

  downloadText(
    markdown,
    filename,
    "text/markdown;charset=utf-8"
  );

  console.log(
    logPrefix,
    `Downloaded "${filename}"`
  );
})();
