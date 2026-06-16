export interface AdfDoc {
  type: 'doc';
  version: 1;
  content: AdfBlock[];
}

type InlineNode = { type: 'text'; text: string; marks?: Mark[] };
type Mark =
  | { type: 'strong' }
  | { type: 'em' }
  | { type: 'code' }
  | { type: 'link'; attrs: { href: string } };

type AdfBlock =
  | { type: 'paragraph'; content: InlineNode[] }
  | { type: 'heading'; attrs: { level: 1 | 2 | 3 }; content: InlineNode[] }
  | { type: 'codeBlock'; attrs: { language?: string }; content: [{ type: 'text'; text: string }] }
  | { type: 'bulletList'; content: ListItem[] }
  | { type: 'orderedList'; content: ListItem[] };

type ListItem = {
  type: 'listItem';
  content: [{ type: 'paragraph'; content: InlineNode[] }];
};

/**
 * Convert inline markdown markup (bold, italic, code, link) into ADF inline nodes.
 *
 * KNOWN LIMITATIONS (HIMMEL-101 §9):
 * - No recursion: `**bold *with italic* inside**` is parsed as a single strong run;
 *   the inner italic asterisks are consumed by the outer regex and not re-tokenized.
 * - No escaped delimiters: `\*literal\*` is treated like `*literal*` (parsed as italic).
 * - No multi-line marks: a mark must open and close on the same line. (The wider
 *   markdown parser flattens paragraphs first, so a line-broken mark in markdown
 *   source becomes a single line here and IS supported.)
 *
 * For documents that need full CommonMark fidelity, swap this for markdown-it's
 * inline tokenizer. Today's `jira-create` flow stays inside the supported subset.
 */
function parseInline(text: string): InlineNode[] {
  const out: InlineNode[] = [];
  const regex =
    /(\*\*[^*]+\*\*|__[^_]+__|`[^`]+`|\[[^\]]+\]\([^)]+\)|\*[^*]+\*|_[^_]+_)/g;
  let lastIdx = 0;
  for (const m of text.matchAll(regex)) {
    if (m.index! > lastIdx) {
      out.push({ type: 'text', text: text.slice(lastIdx, m.index) });
    }
    const tok = m[0];
    if (tok.startsWith('**') || tok.startsWith('__')) {
      out.push({ type: 'text', text: tok.slice(2, -2), marks: [{ type: 'strong' }] });
    } else if (tok.startsWith('`')) {
      out.push({ type: 'text', text: tok.slice(1, -1), marks: [{ type: 'code' }] });
    } else if (tok.startsWith('[')) {
      const lm = tok.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      if (lm) {
        out.push({ type: 'text', text: lm[1], marks: [{ type: 'link', attrs: { href: lm[2] } }] });
      } else {
        out.push({ type: 'text', text: tok });
      }
    } else if (tok.startsWith('*') || tok.startsWith('_')) {
      out.push({ type: 'text', text: tok.slice(1, -1), marks: [{ type: 'em' }] });
    }
    lastIdx = m.index! + tok.length;
  }
  if (lastIdx < text.length) {
    out.push({ type: 'text', text: text.slice(lastIdx) });
  }
  return out.length ? out : [{ type: 'text', text }];
}

export function markdownToAdf(md: string): AdfDoc {
  const lines = md.split('\n');
  const blocks: AdfBlock[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // skip blank lines
    if (!line.trim()) {
      i++;
      continue;
    }

    // code fence
    if (line.startsWith('```')) {
      const lang = line.slice(3).trim() || undefined;
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) {
        codeLines.push(lines[i]);
        i++;
      }
      if (i >= lines.length) {
        process.stderr.write('jira: warning — unclosed code fence in markdown input (treating remainder as code)\n');
      } else {
        i++; // skip closing fence
      }
      blocks.push({
        type: 'codeBlock',
        attrs: lang ? { language: lang } : {},
        content: [{ type: 'text', text: codeLines.join('\n') }],
      });
      continue;
    }

    // heading
    const hMatch = line.match(/^(#{1,3})\s+(.+)$/);
    if (hMatch) {
      // HIMMEL-101 §10: clamp defensively even though the regex `#{1,3}` already
      // bounds the count. If a future regex relaxation allows #{1,6}, this clamp
      // keeps the ADF type-correct (and a violation surfaces as a runtime guard,
      // not a silent type cast).
      const rawLevel = hMatch[1].length;
      const level: 1 | 2 | 3 = rawLevel <= 1 ? 1 : rawLevel >= 3 ? 3 : 2;
      blocks.push({
        type: 'heading',
        attrs: { level },
        content: parseInline(hMatch[2]),
      });
      i++;
      continue;
    }

    // unordered list
    if (/^[-*]\s+/.test(line)) {
      const items: ListItem[] = [];
      while (i < lines.length && /^[-*]\s+/.test(lines[i])) {
        items.push({
          type: 'listItem',
          content: [
            { type: 'paragraph', content: parseInline(lines[i].replace(/^[-*]\s+/, '')) },
          ],
        });
        i++;
      }
      blocks.push({ type: 'bulletList', content: items });
      continue;
    }

    // ordered list
    if (/^\d+\.\s+/.test(line)) {
      const items: ListItem[] = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
        items.push({
          type: 'listItem',
          content: [
            { type: 'paragraph', content: parseInline(lines[i].replace(/^\d+\.\s+/, '')) },
          ],
        });
        i++;
      }
      blocks.push({ type: 'orderedList', content: items });
      continue;
    }

    // paragraph — accumulate consecutive non-blank, non-special lines
    const paraLines: string[] = [line];
    i++;
    while (
      i < lines.length &&
      lines[i].trim() &&
      !lines[i].startsWith('```') &&
      !/^(#{1,3}\s|[-*]\s|\d+\.\s)/.test(lines[i])
    ) {
      paraLines.push(lines[i]);
      i++;
    }
    blocks.push({ type: 'paragraph', content: parseInline(paraLines.join(' ')) });
  }

  return { type: 'doc', version: 1, content: blocks };
}
