# excalidraw-style.json

The look sheet for `:ExportToExcalidraw` (`after/plugin/markdown_excalidraw.lua`),
resolved by `lua/shared/excalidraw_style.lua`. The counterpart of mdpdf's
`default-styles/*.tex` for the pdf/docx exports, minus the profiles: a canvas
is one look, so there is one file and the command takes no style argument.

Everything about how an exported document *looks* is here — nothing is
hardcoded in the nvim plugin or in the Excalidraw app. The resolved table
travels with the document to the app, which draws it
(`~/excalidraw-src/app/src/document.js`); a missing key falls back there, so a
partial file is fine, and deleting the file entirely still exports (with
built-in defaults) rather than failing.

## keys

| key | meaning |
|-----|---------|
| `page.contentWidth` | the column width in px — what prose wraps at, and what a diagram is scaled down to |
| `page.background` | canvas background colour |
| `roughness` | 0 architect, 1 artist, 2 cartoonist — the hand-drawn-ness of every box and line |
| `fonts.body` / `fonts.heading` / `fonts.code` | Excalidraw font names: `Nunito`, `Excalifont`, `Liberation Sans`, `Helvetica`, `Cascadia`, `Comic Shanns`, `Lilita One`, `Virgil` |
| `title.{size,color,gapAfter}` | the `/title` line — XL by default (36) |
| `headings.1` … `headings.6` | `{size, color, gapBefore, gapAfter}` per level; `1` is L (28) |
| `paragraph.{size,color,gapAfter}` | prose |
| `list.{size,color,indent,gapAfter}` | lists; `indent` is px per nesting level |
| `list.bullets` | markers by depth, cycled — e.g. `["•", "–", "◦"]` |
| `list.checked` / `list.unchecked` | task markers, `[x]` / `[ ]` |
| `quote.{size,color,barColor,barWidth,indent,gapAfter}` | blockquote and its left bar |
| `code.{size,padding,background,border,text,gapAfter}` | the code box |
| `code.rounded` | corner style of the box; square (`false`) by default |
| `code.wrap` | soft-wrap long lines at the column edge (default `true`); `false` lets the box grow instead |
| `code.lineNumbers`, `code.lineNumberColor` | the gutter |
| `code.headingSize`, `code.headingColor` | the fence's heading line (` ```js src/main.js `) — small and grey |
| `code.tokens` | treesitter capture -> colour, e.g. `{"keyword": "#cf222e"}` |
| `table.{size,color,border,headerBackground,cellBackground,cellPaddingX,cellPaddingY,minColumnWidth,gapAfter}` | tables |
| `image.{gapAfter,captionSize,captionColor}` | embedded images and their alt-text caption |
| `diagram.{fontSize,fitToWidth,gapAfter}` | mermaid diagrams |
| `rule.{color,gapAfter}` | `---` |
| `spacer.height` | what one `/newline` is worth |
| `toc.{size,color,indent,gapAfter}` | `/toc` |

### `code.tokens`

Keys are treesitter capture names **without the `@`**, and a capture resolves up
its own hierarchy: `@function.method.call` tries `function.method.call`, then
`function.method`, then `function`, then falls back to `code.text`. So naming
the broad categories (`keyword`, `string`, `number`, `comment`, `function`,
`type`, `variable`, `operator`, `punctuation`) covers every language, and a
specific capture can be picked out when one is worth its own colour.

Which captures a language actually produces is whatever nvim's `highlights.scm`
for it produces — `:Inspect` on a token in a real buffer names it.

## theme

The colours here are written for a light canvas. The app runs dark by default
(`exapp --light` for a light one) and Excalidraw's dark mode inverts element
colours as it renders, so a light style still reads correctly in a dark
editor — it is the same treatment a hand-drawn scene gets.
