(() => {
  const x = window.__chatExport;
  if (!x?.numbers?.length) throw new Error('No captured chat export found.');

  const md = x.numbers.map(n => {
    const t = x.collected.get(n);

    let out = `## Turn ${n}\n\n`;

    if (t.user) {
      out += `### User\n\n${t.user}\n\n`;
    }

    if (t.assistant) {
      out += `### Assistant\n\n${t.assistant}\n\n`;
    }

    if (!t.user && !t.assistant && t.whole) {
      out += `${t.whole}\n\n`;
    }

    return out;
  }).join('---\n\n');

  const date = new Date().toISOString().slice(0, 10);

  const rawTitle =
    document.title
      .replace(/\s*[-–—]\s*ChatGPT\s*$/i, '')
      .replace(/^ChatGPT\s*[-–—]\s*/i, '')
      .trim() || 'Chat Export';

  const safeTitle = rawTitle
    .replace(/[\/\\:*?"<>|]/g, '-')
    .replace(/\s+/g, ' ')
    .trim();

  const filename = `${date} - ${safeTitle}.md`;

  const blob = new Blob([md], {
    type: 'text/markdown;charset=utf-8'
  });

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');

  a.href = url;
  a.download = filename;

  document.body.appendChild(a);
  a.click();
  a.remove();

  setTimeout(() => URL.revokeObjectURL(url), 1000);

  console.log(
    `Downloaded "${filename}" — ${x.numbers.length} turns, ${md.length.toLocaleString()} characters.`
  );
})();
