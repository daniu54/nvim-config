#!/usr/bin/env node
"use strict";

// Explode an HTML document: essentially every element onto its own line.
//
// This exists because prettier alone cannot do it in one pass. `--print-width
// 1` is what actually forces a break at every tag, but print width is global,
// so the same setting shreds an embedded <script> into unreadable vertical
// confetti (`(\n  (a =\n    window.google) ==\n  null\n    ? 0\n ...`). The
// two concerns want opposite widths: the markup wants 1, the code inside it
// wants a normal one.
//
// Text nodes have the same problem for the same reason: width 1 breaks a
// paragraph at every space, one word per line.
//
// So the width-1 pass is sandwiched between passes that keep it away from
// everything that is not a tag:
//
//   1. formatEmbedded  <script>/<style> bodies formatted at EMBED_WIDTH.
//   2. protectText     spaces inside text nodes swapped for a sentinel, so
//                      each node is one unbreakable "word".
//   3. the markup pass printWidth 1, embeddedLanguageFormatting off — so it
//                      only re-indents the bodies from (1) and cannot split
//                      the text from (2). Tags are all that is left to break.
//   4. wrapText        sentinels back to spaces, those lines wrapped at
//                      TEXT_WIDTH under their own indent.
//
// Handling the embedded bodies first (rather than exploding and repairing
// after) means nothing has to find them again in the exploded output, where an
// opening tag's attributes are spread over many lines.
//
// Every pass is idempotent, which is the property that matters most here: this
// is also conform's html formatter, so :w runs it over its own output and must
// not drift. The subtle one is dedent() — see there.
//
// Reads a document on stdin, writes the exploded one on stdout. That is the
// shape conform.nvim wants, and it keeps this usable from a plain shell pipe.

const path = require("path");
const os = require("os");

function loadPrettier() {
  // Installed globally under a home-relative npm prefix, so a bare require
  // only resolves when this happens to run from inside that tree.
  const candidates = [
    "prettier",
    path.join(os.homedir(), ".npm-global/lib/node_modules/prettier"),
    "/usr/local/lib/node_modules/prettier",
    "/usr/lib/node_modules/prettier",
  ];
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (err) {
      if (err && err.code !== "MODULE_NOT_FOUND") throw err;
    }
  }
  process.stderr.write(
    "html-explode: cannot find the prettier module (tried: " +
      candidates.join(", ") +
      ")\n",
  );
  process.exit(2);
}

const prettier = loadPrettier();

// Wide enough that formatting a <script> is an improvement over the minified
// line it replaces, without the markup's width-1 rule leaking into it.
const EMBED_WIDTH = Number(process.env.HTML_EXPLODE_EMBED_WIDTH) || 100;

// Text nodes are re-wrapped to this after the markup pass. Same reasoning as
// EMBED_WIDTH: only the tags want width 1.
const TEXT_WIDTH = Number(process.env.HTML_EXPLODE_TEXT_WIDTH) || 100;

// A private-use codepoint, so it cannot occur in real markup. It stands in for
// the spaces inside a text node while the width-1 pass runs -- see protectText.
const SENTINEL = "\uE000";

const MARKUP_OPTIONS = {
  parser: "html",
  printWidth: 1,
  htmlWhitespaceSensitivity: "ignore",
  embeddedLanguageFormatting: "off",
  tabWidth: 2,
};

// `type` decides what a <script> body actually is. An unknown type is a
// template language or a data blob we have no business reformatting, so it is
// left exactly as found rather than guessed at.
const SCRIPT_PARSERS = new Map([
  ["", "babel"],
  ["module", "babel"],
  ["text/javascript", "babel"],
  ["application/javascript", "babel"],
  ["text/ecmascript", "babel"],
  ["application/ecmascript", "babel"],
  ["text/babel", "babel"],
  ["json", "json"],
  ["importmap", "json"],
  ["speculationrules", "json"],
  ["application/json", "json"],
  ["application/ld+json", "json"],
]);

function attr(attrs, name) {
  const m = attrs.match(
    new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s"'>]+))`, "i"),
  );
  if (!m) return null;
  return (m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4]).trim();
}

function embeddedParser(tag, attrs) {
  if (tag.toLowerCase() === "style") {
    const type = (attr(attrs, "type") || "text/css").toLowerCase();
    return type === "text/css" ? "css" : null;
  }
  // A <script src=...> has no body worth formatting even if it holds text.
  if (attr(attrs, "src")) return null;
  const type = (attr(attrs, "type") || "").toLowerCase();
  return SCRIPT_PARSERS.get(type) || null;
}

// Non-greedy body, so the first matching close tag wins. A JS string cannot
// contain a literal `</script>` without escaping it, so this cannot cut a
// block short in a valid document.
const EMBEDDED_BLOCK = /(<(script|style)\b([^>]*)>)([\s\S]*?)(<\/\2\s*>)/gi;

// Strip the block's common indentation before formatting it.
//
// This is what makes a second run a no-op. The markup pass indents every line
// of a raw body under its tag, and prettier reproduces the interior lines of a
// block comment verbatim — so a `/* ... */` inside a <script> collects another
// level of indentation on every run, forever, while the code around it stays
// put. Normalising the body back to column 0 first means the indentation the
// markup pass adds is the only indentation there is.
function dedent(body) {
  const lines = body.split("\n");
  // The first line sits after the opening tag rather than at a line start, so
  // it carries no indentation to measure and is handled on its own.
  let common = null;
  for (const line of lines.slice(1)) {
    if (!line.trim()) continue;
    const indent = line.match(/^[ \t]*/)[0].length;
    if (common === null || indent < common) common = indent;
  }
  if (!common) return body;
  return [lines[0], ...lines.slice(1).map((line) => line.slice(common))].join("\n");
}

async function formatEmbedded(source) {
  const jobs = [];
  // Collect first, format concurrently, splice after: replace() cannot await.
  source.replace(EMBEDDED_BLOCK, (match, open, tag, attrs, body, close, offset) => {
    const parser = embeddedParser(tag, attrs);
    if (parser && body.trim()) {
      jobs.push({ parser, body, start: offset + open.length, end: offset + open.length + body.length });
    }
    return match;
  });

  const formatted = await Promise.all(
    jobs.map((job) =>
      prettier
        .format(dedent(job.body), { parser: job.parser, printWidth: EMBED_WIDTH, tabWidth: 2 })
        // A body that does not parse (a template fragment, a deliberate syntax
        // error, a language we guessed wrong) keeps its original text. One bad
        // block must not cost the whole document its formatting.
        .catch(() => null),
    ),
  );

  let out = "";
  let cursor = 0;
  jobs.forEach((job, i) => {
    if (formatted[i] === null) return;
    out += source.slice(cursor, job.start) + "\n" + formatted[i].trim() + "\n";
    cursor = job.end;
  });
  return out + source.slice(cursor);
}

// Elements that hold text nobody may reflow: their own bodies are either code
// we already formatted, or whitespace-significant by definition.
const RAW_TEXT = /<(script|style|pre|textarea)\b[^>]*>[\s\S]*?<\/\1\s*>/gi;
const COMMENT = /<!--[\s\S]*?-->/g;
const TAG = /<[^>]*>/g;

// Hide the spaces inside text nodes from the width-1 pass.
//
// printWidth is not selective: the setting that forces a break at every tag
// also breaks every text node at every space, so a paragraph comes back one
// word per line. Prettier can only break a line where there is whitespace, so
// substituting a non-space character for the spaces in a text node makes that
// node a single unbreakable "word" -- it lands on one line, intact, and the
// tags around it still explode. wrapText() puts real spaces back afterwards
// and wraps the line at a width chosen for prose rather than for markup.
//
// Runs of whitespace collapse to one sentinel, which is what a browser does
// with them anyway, and is also why the sentinel is a single character rather
// than one per space.
function protectText(source) {
  // Everything that is not a text node, in one pass, so a `<` inside a script
  // string or a comment can never be mistaken for the start of a tag.
  const skip = new RegExp(
    [RAW_TEXT.source, COMMENT.source, TAG.source].join("|"),
    "gi",
  );
  let out = "";
  let cursor = 0;
  for (const match of source.matchAll(skip)) {
    out += protectChunk(source.slice(cursor, match.index)) + match[0];
    cursor = match.index + match[0].length;
  }
  return out + protectChunk(source.slice(cursor));
}

function protectChunk(text) {
  if (!text.trim()) return text;
  return text.replace(/\s+/g, SENTINEL).replace(/^\uE000|\uE000$/g, "");
}

// Put the spaces back, wrapping the restored line at TEXT_WIDTH under its own
// indent. Only lines carrying a sentinel are touched, which is what makes this
// safe: they are exactly the text nodes protectText marked, so a line of code
// inside a <script> can never be reflowed as if it were prose.
function wrapText(source) {
  const out = [];
  for (const line of source.split("\n")) {
    if (!line.includes(SENTINEL)) {
      out.push(line);
      continue;
    }
    const indent = line.match(/^[ \t]*/)[0];
    const words = line.slice(indent.length).split(SENTINEL);
    // Never let a deep indent squeeze the text to nothing.
    const width = Math.max(TEXT_WIDTH - indent.length, 20);
    let current = "";
    for (const word of words) {
      if (current && current.length + 1 + word.length > width) {
        out.push(indent + current);
        current = word;
      } else {
        current = current ? current + " " + word : word;
      }
    }
    if (current) out.push(indent + current);
  }
  return out.join("\n");
}

async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const source = Buffer.concat(chunks).toString("utf8");

  let text = await formatEmbedded(source);
  text = protectText(text);
  text = await prettier.format(text, MARKUP_OPTIONS);
  process.stdout.write(wrapText(text));
}

main().catch((err) => {
  process.stderr.write("html-explode: " + (err && err.message ? err.message : String(err)) + "\n");
  process.exit(1);
});
