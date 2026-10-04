(async () => {
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  const TURN_SELECTOR = '[data-content-search-turn-key]';
  const SCROLLER_SELECTOR = '.thread-scroll-container';

  const scroller = document.querySelector(SCROLLER_SELECTOR);

  if (!scroller) {
    console.error(
      `EXPORT ABORTED: could not find ${SCROLLER_SELECTOR}`
    );
    return;
  }

  function turnNumber(el) {
    const key = el.getAttribute('data-content-search-turn-key') || '';
    const m = key.match(/^fallback-turn-(\d+)$/);
    return m ? Number(m[1]) : null;
  }

  function cleanText(s) {
    return (s || '')
      .replace(/\u00a0/g, ' ')
      .replace(/\r\n/g, '\n')
      .trim();
  }

  function extractTurn(el) {
    const number = turnNumber(el);
    if (number === null) return null;

    const userBubble =
      el.querySelector('[data-user-message-bubble="true"]');

    const assistantMarker =
      el.querySelector('[data-chatgpt-agent-turn-start]');

    const assistantUnit =
      assistantMarker?.closest('[data-content-search-unit-key]');

    const user = cleanText(userBubble?.innerText);

    let assistant = cleanText(assistantUnit?.innerText);

    if (!assistant && assistantMarker?.parentElement) {
      assistant = cleanText(
        assistantMarker.parentElement.innerText
      );
    }

    return {
      number,
      key: `fallback-turn-${number}`,
      user,
      assistant,
      whole: cleanText(el.innerText)
    };
  }

  const collected = new Map();

  function collectMounted() {
    const mounted = [
      ...document.querySelectorAll(TURN_SELECTOR)
    ];

    for (const el of mounted) {
      const turn = extractTurn(el);

      if (turn) {
        collected.set(turn.number, turn);
      }
    }

    const nums = [
      ...collected.keys()
    ].sort((a, b) => a - b);

    console.log(
      `Collected ${collected.size} turns; ` +
      `range ${nums[0] ?? '?'}–${nums.at(-1) ?? '?'}; ` +
      `scrollTop=${Math.round(scroller.scrollTop)}`
    );
  }

  console.log(
    'ChatGPT reverse-scroll exporter starting.'
  );

  console.log({
    clientHeight: scroller.clientHeight,
    scrollHeight: scroller.scrollHeight,
    initialScrollTop: scroller.scrollTop
  });

  /*
   * ChatGPT lazy-loads older history as we approach
   * the beginning of long conversations.
   *
   * Therefore:
   *
   *   -(scrollHeight - clientHeight)
   *
   * is only the currently-known beginning.
   *
   * We repeatedly jump to the currently-known beginning,
   * wait for older history to load, recalculate the new
   * beginning, and continue until fallback-turn-0 is
   * actually mounted.
   */
  async function reachTrueBeginning() {
    const MAX_ATTEMPTS = 200;
    const NORMAL_SETTLE_MS = 1000;
    const EXTRA_SETTLE_MS = 1500;

    let previousScrollHeight = -1;
    let unchangedHeightCount = 0;

    for (
      let attempt = 1;
      attempt <= MAX_ATTEMPTS;
      attempt++
    ) {
      const turnZero = document.querySelector(
        '[data-content-search-turn-key="fallback-turn-0"]'
      );

      if (turnZero) {
        console.log(
          `Verified fallback-turn-0 after ` +
          `${attempt - 1} top-seeking attempts.`
        );

        return true;
      }

      const beforeHeight = scroller.scrollHeight;

      const apparentTop =
        -(scroller.scrollHeight - scroller.clientHeight);

      console.log(
        `Seeking beginning: attempt ${attempt}; ` +
        `scrollHeight=${beforeHeight}; ` +
        `target=${Math.round(apparentTop)}`
      );

      scroller.scrollTop = apparentTop;

      await sleep(NORMAL_SETTLE_MS);

      const afterHeight = scroller.scrollHeight;

      /*
       * If the scroll extent changed, ChatGPT loaded
       * more history. Loop immediately so the new
       * farther-away beginning is recalculated.
       */
      if (afterHeight !== previousScrollHeight) {
        previousScrollHeight = afterHeight;
        unchangedHeightCount = 0;
      } else {
        unchangedHeightCount++;
      }

      /*
       * If the extent appears stable for a couple
       * attempts, hit the boundary again and allow
       * additional time for lazy loading.
       */
      if (unchangedHeightCount >= 2) {
        const refreshedTop =
          -(
            scroller.scrollHeight -
            scroller.clientHeight
          );

        scroller.scrollTop = refreshedTop;

        await sleep(EXTRA_SETTLE_MS);

        unchangedHeightCount = 0;
      }
    }

    return !!document.querySelector(
      '[data-content-search-turn-key="fallback-turn-0"]'
    );
  }

  const reachedBeginning =
    await reachTrueBeginning();

  if (!reachedBeginning) {
    console.error(
      'EXPORT ABORTED: could not reach ' +
      'fallback-turn-0 after repeated lazy-load attempts.'
    );

    console.error({
      scrollTop: scroller.scrollTop,
      clientHeight: scroller.clientHeight,
      scrollHeight: scroller.scrollHeight
    });

    return;
  }

  console.log(
    'Verified true beginning. Beginning capture.'
  );

  collectMounted();

  /*
   * Once we have proven the true beginning exists,
   * walk forward through the conversation toward
   * scrollTop = 0.
   *
   * The relatively small step gives virtualized
   * turns plenty of overlap so we are less likely
   * to skip one between renders.
   */
  const step = Math.max(
    200,
    Math.floor(scroller.clientHeight * 0.40)
  );

  let iterations = 0;
  let lastPosition = scroller.scrollTop;
  let stalled = 0;

  while (scroller.scrollTop < -1) {
    iterations++;

    const target = Math.min(
      0,
      scroller.scrollTop + step
    );

    scroller.scrollTop = target;

    await sleep(300);

    collectMounted();

    const now = scroller.scrollTop;

    if (
      Math.abs(now - lastPosition) < 1
    ) {
      stalled++;
    } else {
      stalled = 0;
    }

    lastPosition = now;

    if (stalled >= 10) {
      console.warn(
        'Scrolling stalled before reaching zero; ' +
        'attempting final jump.'
      );

      break;
    }

    if (iterations > 20000) {
      console.error(
        'EXPORT ABORTED: safety iteration limit reached.'
      );

      return;
    }
  }

  /*
   * Final end-of-chat collection after allowing
   * virtualization to settle.
   */
  scroller.scrollTop = 0;

  await sleep(1200);

  collectMounted();

  const numbers = [
    ...collected.keys()
  ].sort((a, b) => a - b);

  if (!numbers.length) {
    console.error(
      'EXPORT ABORTED: no turns collected.'
    );

    return;
  }

  const first = numbers[0];
  const last = numbers.at(-1);

  const missing = [];

  for (let i = first; i <= last; i++) {
    if (!collected.has(i)) {
      missing.push(i);
    }
  }

  const emptyUser = numbers.filter(
    n => !collected.get(n).user
  );

  const emptyAssistant = numbers.filter(
    n => !collected.get(n).assistant
  );

  const emptyWhole = numbers.filter(
    n => !collected.get(n).whole
  );

  console.log(
    '========================================'
  );

  console.log(
    'COLLECTION COMPLETE'
  );

  console.log(
    'Turns collected:',
    collected.size
  );

  console.log(
    'First turn:',
    first
  );

  console.log(
    'Last turn:',
    last
  );

  console.log(
    'Missing turns:',
    missing
  );

  console.log(
    'Turns with empty user text:',
    emptyUser
  );

  console.log(
    'Turns with empty assistant text:',
    emptyAssistant
  );

  console.log(
    'Turns with no rendered text at all:',
    emptyWhole
  );

  console.log(
    '========================================'
  );

  /*
   * Keep the validated collection available
   * for the separate Markdown export command.
   */
  window.__chatExport = {
    collected,
    numbers,
    first,
    last,
    missing,
    emptyUser,
    emptyAssistant,
    emptyWhole
  };

  /*
   * Validation remains fail-closed.
   */
  if (first !== 0) {
    console.error(
      `VALIDATION FAILED: first turn is ` +
      `${first}, expected 0.`
    );

    return;
  }

  if (missing.length) {
    console.error(
      'VALIDATION FAILED: missing turn numbers:',
      missing
    );

    return;
  }

  if (emptyWhole.length) {
    console.error(
      'VALIDATION FAILED: some turns contain ' +
      'no rendered text:',
      emptyWhole
    );

    return;
  }

  console.log(
    'VALIDATION PASSED. Captured data is in ' +
    'window.__chatExport.'
  );

  console.log(
    'No file has been downloaded yet.'
  );
})();
