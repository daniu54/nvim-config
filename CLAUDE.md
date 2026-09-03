# nvim config — CLAUDE.md

Instructions and context for Claude Code when working in this repository.

## obsidian documentation

When the user asks to document keybindings or config changes in Obsidian, write to:

- **Folder:** `D:\obsidian_notes\default_vault\default\nvim\` (Windows path — use `wslpath` if needed: `/mnt/d/obsidian_notes/default_vault/default/nvim/`)
- **File:** `nvim.md`

## plugin manager

**lazy.nvim** — migrated from packer.nvim.

`lua/shared/lazy.lua` is the plugin setup file. It uses lazy.nvim.

packer.nvim is gone and fully replaced. `plugin/packer_compiled.lua` is gitignored (stale artifact). Ignore it.

## config structure

```
init.lua                    — entry point: requires("shared")
excalidraw-style.json       — the look sheet for :ExportToExcalidraw
excalidraw-style.md         — its key reference
lua/shared/
  init.lua                  — loads remap, set, packer, wt_colors
  md_document.lua           — markdown → typed blocks + treesitter code tokens
  yank_store.lua            — the yank history: an append-only JSON-lines log
  nvfuzzy.lua               — the editor half of the shell's `nv <pattern>`
  open_under_cursor.lua     — <CR> on a path/URL: nvim, Firefox or Explorer
  excalidraw_style.lua      — loads excalidraw-style.json
  lazy.lua                  — plugin definitions (lazy.nvim)
  remap.lua                 — keymaps
  set.lua                   — vim options
  wt_colors.lua             — Windows Terminal background color sync
  copilot.lua               — shared Copilot infra (bootstrap, sensitive-file check, opt-in helper, <Right>/<S-Right>)
after/plugin/
  autosave.lua              — autosave file-backed buffers (:AutoSaveToggle)
  tabs.lua                  — tab management: the <C-f> chord + Home/End
  yanks.lua                 — :Yanks / <C-p>, the yank history as a buffer
  git_review.lua            — :GitReview, the branch's commits+diffs as markdown
  markdown_convert.lua      — :ConvertToPdf/:ConvertToTex/:ConvertToWord via mdpdf
  markdown_excalidraw.lua   — :ExportToExcalidraw (whole document → canvas)
  excalidraw_render.lua     — :ExcalidrawRender (```mermaid blocks only)
  markdown_table.lua        — Obsidian-style table editing (<Tab>/<CR> grow the table)
  colors.lua                — colorscheme (rose-pine) + all custom highlight groups (Search, terminal visual, NetrwDotfile, etc.)
  conform.lua               — formatter config
  harpoon.lua               — harpoon2 config
  telescope.lua             — telescope config
  cmp.lua                   — nvim-cmp completion (buffer + path + lsp)
  lsp.lua                   — on-demand pyright LSP via :LspEnable
  copilot.lua               — Copilot inline completion, opt-in per project (<leader>la)
  copilot_chat.lua          — Copilot Chat region-refactor keymap (<leader>lr)
plugin/
  packer_compiled.lua       — gitignored, stale packer artifact
```

## code blocks in markdown are highlighted per language

A ```` ```cs ```` block in a markdown buffer is coloured as C#, not as one flat
`@markup.raw.block` blue. **No plugin does this** — markdown's own treesitter
grammar *injects* the fence's language, so the whole feature is two things being
true in `lua/shared/lazy.lua`:

- **The parser is installed.** `ensure_installed` is therefore also the list of
  languages a fence can be coloured in: `java`, `c_sharp`, `kotlin`,
  `javascript`, `typescript`, `tsx`, `html`, `css`, `sql`, `mermaid`, `json`,
  `bash`, `python`, plus `lua`/`markdown`/`markdown_inline`/`yaml`/`zig`. A
  language with no parser falls back to the flat fence colour — that is the
  symptom, not an error.
- **The fence word resolves to a parser.** Injection resolves the info string
  through `vim.treesitter.language.get_lang`, which knows *filetypes* — so
  ```` ```cs ```` works for free (nvim-treesitter registers `c_sharp` for
  filetype `cs`) while ```` ```js ````, ```` ```ts ```` and ```` ```yml ````
  resolve to nothing. The config registers `md_document.LANG_ALIASES` — the
  same table `:ExportToExcalidraw` highlights code with — as filetype aliases at
  startup, so **a fence that exports coloured also renders coloured**, and there
  is one list to add to rather than two.

## markdown export (:ConvertToPdf / :ConvertToTex / :ConvertToWord)

`after/plugin/markdown_convert.lua` drives the `mdpdf` binary
(`/mnt/d/Programming/claude-projects/markdown-to-pdf`, override with
`$MDPDF_BIN`). The export lands **beside the source file**; the LaTeX/mermaid
artifacts stay in a cached `/tmp/mdpdf-build/<stem>-<hash>` directory that is
never deleted.

- The buffer is written first if modified — mdpdf reads the file from disk, so
  an unwritten buffer would silently export stale content.
- Progress is streamed into a scratch split rather than `vim.notify`d: a cold
  build is pandoc + a headless-Chromium mermaid render + two pdflatex passes and
  can take a minute, and it can fail halfway. mdpdf prints one `==>` line per
  phase for exactly this.
- **The contract with mdpdf is its last two stdout lines**, `BUILD DIR:` and
  `OUTPUT:`. The plugin parses them for the completion notification. Changing
  either format in mdpdf breaks this plugin.
- `:ConvertToPdf!` (bang) passes `--clean` — discard cached artifacts.
- An optional argument is the **style profile**: `:ConvertToPdf academic`.
  `<Tab>` completes it from `mdpdf --list-styles`, so the list can never drift
  from what the binary ships. Default is `word` — a Word-export look; `academic`
  is the numbered-sections paper look.
- `:ConvertOpenBuildDir` opens the cache via `mdpdf --print-build-dir`.

Markdown authoring features mdpdf adds on top of pandoc:

- `/comment <text>` — a line comment, dropped from the export.
- `/ignore` … `/endignore` — drops that region. **An `/ignore` with no
  `/endignore` drops the rest of the file**, which is the intended reading for
  a file with a finished document at the top and a scratchpad underneath, not
  an error. A stray `/endignore` is removed and warned about.
- `/title My Cool Document` — the document's title, on its own line, optional.
  It is **not a heading**: no section number, no contents entry, and the
  sections under it are not renumbered. In `.docx` it becomes Word's own
  **Title** paragraph style, so it follows the document theme. Inline markdown
  in the title works.
- `/newpage` (alias `/pagebreak`) starts a new page; `/newline` (alias
  `/blankline`) inserts one blank line. `/newline` exists because a plain blank
  line gets collapsed by formatters and ignored by pandoc — three `/newline`
  lines really do give three lines.
- `/tableofcontents` (alias `/toc`) — a table of contents right there, with no
  heading above it. `## Heading {.notoc}` keeps a section out of it (pdf/tex
  only — a Word TOC is built from heading styles).
- ```` ```mermaid ```` fenced blocks render as diagrams.
- **Code blocks** are syntax-highlighted, line-numbered (grey), and can carry a
  heading and a jump id on the fence line:
  ```` ```js #main src/main.js ````. File extensions work as language names
  (`js`, `ts`, `sh`, `ps1`, `cs`, `yml`, `py`, `scss`, `htm`, plus `sql` and
  `dockerfile`); pandoc knows none of the abbreviations. Default colour scheme
  is `kate`.
  Windows paths in a heading survive verbatim. `[see it](#main)` jumps to the
  block. `--highlight-style <name>`/`none` changes the colours,
  `--no-line-numbers` (or `.nolinenumbers` on one block) drops the numbers.
  Long lines wrap and long blocks split across pages. Line numbers are pdf/tex
  only — Word cannot number per block.
- **Cross-references** that jump in pdf/tex/docx. `[text](#my-section-title)`,
  `## Heading {#custom-id}`, or the section's name written out —
  `[text](#My Section Title)`. For a target that is not a heading, put
  `{#the-spot}` on a line of its own. Links work inside table cells. A link
  resolving to nothing is reported on stderr rather than silently dead.

## markdown → excalidraw (:ExportToExcalidraw)

`after/plugin/markdown_excalidraw.lua` exports the **whole** buffer to an
Excalidraw canvas — headings, prose, lists, quotes, tables, syntax-highlighted
code, embedded images and every ```mermaid block — laid out in one column, as
if it had been typed there. `:ExcalidrawRender` (diagrams only) stays as it is;
this is the document-shaped sibling of `:ConvertToPdf` / `:ConvertToWord`, and
it reads the same mdpdf dialect (`/title`, `/comment`, `/ignore`../`/endignore`,
`/newline`, `/toc`, `{#id}`/`{.notoc}`, the `#anchor Heading` fence line), so a
document written for mdpdf exports here unchanged. **`/newpage` is parsed and
dropped** — a canvas has no pages.

- `:ExportToExcalidraw` writes `<stem>.excalidraw` beside the document and
  opens it in the local editor; a re-export overwrites it, like re-running
  `:ConvertToPdf`. **Edits made in the canvas are lost on the next export** —
  the markdown is the source.
- `:ExportToExcalidraw!` renders to a scratch file under `stdpath("cache")`
  instead, for a look at a document you do not want an `.excalidraw` next to.
- The look is `excalidraw-style.json` at the config root (keys documented in
  `excalidraw-style.md`) — one file, no profiles, so the command takes no
  argument. A canvas is one look; a second profile was churn with nothing to
  choose between.

**Half of this feature lives in ~/excalidraw-src/app** (`src/document.js`), and
the split is the design: laying a document out needs a browser. Wrapping a line
means measuring a string in a font; a mermaid diagram lays out in a DOM; an
image has to be decoded to learn its size; and Excalidraw's per-font line
height is not exported by the package, so it is read off a converted element.
None of that is available in Lua.

So this file does only what can be decided by reading text — parsing markdown
into typed blocks (`lua/shared/md_document.lua`), tokenising code with
treesitter, reading images into data URLs, resolving the style — and hands the
result to `exapp-render-doc`, which POSTs it to `/api/render-document` in the
running editor. Same hand-off as `:ExcalidrawRender`, same reason.

Things worth knowing:

- **Code is highlighted with nvim's own treesitter queries**, and the payload
  carries *capture names*, not colours: the style file maps
  `keyword`/`string`/`comment`/… to colours, so an export does not depend on
  whichever colorscheme happened to be active. A language with no parser
  installed falls back to one colour in the code font, which is the documented
  fallback and not an error. `@spell` and friends are skipped — most queries
  attach `@spell` on top of comments, and letting it win repaints them.
- **A list is one text element**, markers and indents included, ordered and
  unordered alike. Two elements per bullet aligns hanging indents to the pixel
  and is miserable to edit.
- **Inline emphasis is stripped**, because a text element has one font and one
  colour: `**deadline**` would otherwise read as a word with asterisks stuck to
  it. A paragraph or a list that points at exactly one URL keeps it as the
  element's link, which is the one piece of inline markup that survives.
- **Only a line that is nothing but an image becomes an image**; an image in
  the middle of a sentence stays as its alt text. Images are embedded as data
  URLs (so the scene file carries them), capped at 8 MB, and a remote or
  unreadable one leaves a dashed red placeholder naming the path rather than
  disappearing.
- The buffer is exported, not the file on disk — unlike mdpdf, nothing re-reads
  the file, so there is no forced write first.

## markdown tables (ported from Obsidian)

`after/plugin/markdown_table.lua` ports the Obsidian tables plugin's three
behaviours: typing `| name | age |` and pressing `<CR>` (or `<Tab>`) writes the
`| --- | --- |` row and makes it a real table; `<Tab>` moves right and *creates*
a column when there is none; `<CR>` moves to the next row, creating it, and on
an empty last row drops out of the table instead — that is the way out. Plus
`<A-h/l>` `<A-k/j>` insert a column/row, `<A-S-…>` move one, `<A-d>` deletes a
column, `<A-a>` cycles alignment, `<A-t>` inserts a fresh table, `:TableFormat`
reflows. Everything reflows on those keys and on `InsertLeave`.

**It is written against the line text, not treesitter, and deliberately does
not use table-nvim** (SCJangra/table-nvim — the one plugin that does this job).
Both are ruled out by the same thing: *the markdown grammar has no production
for a row of blank cells*, so a table whose last row is empty parses as an
`ERROR` node with no table in it at all. Verified against both the parser
pinned in `lazy-lock.json` and current tree-sitter-markdown, so it is not a
version problem and will not be fixed by a bump. An empty row is exactly what
"`<CR>` makes the next row" has to produce, so anything reading the tree breaks
on its own output from the second row on — table-nvim sidesteps this by filling
new cells with an `x` placeholder, which is the behaviour being avoided here.
Reading the lines as text has no such hole, and it is also why a half-built
table (a lone `| header |` line, invisible to the grammar) is editable.

The cost is that markdown *highlighting* still goes flat over a table with an
empty row — same parser — and comes back once the row has content.

`<Tab>`, `<S-Tab>` and `<CR>` are nvim-cmp's keys and a buffer-local map
shadows a global one, so each handler hands the key back to cmp when the
completion menu is open, mirroring `after/plugin/cmp.lua` (including that
`<CR>` confirms only an explicitly selected entry).

**Because these three keys are contested, the attach conditions are narrower
than "filetype is markdown", and both narrowings are load-bearing:**

- A markdown *file being edited* — `buftype == ''` and `modifiable`. An LSP
  hover float, a telescope preview and plugin scratch windows are all
  `filetype=markdown` on a `nofile` buffer, and none of them wants `<Tab>` and
  `<CR>` rewired.
- Only maps this file actually set are removed again, tracked by the
  `b:markdown_table_maps` flag. The autocmd matches `FileType *` (like
  `markdown_edit.lua`, so a buffer whose filetype changes *away* from markdown
  gets the keys back), but a blind `keymap.del` in that branch would delete
  some *other* plugin's buffer-local `<Tab>`/`<CR>` — telescope's picker keys,
  for one — in any buffer that sets its filetype after its mappings.

## markdown editing keymaps (ported from Obsidian)

`after/plugin/markdown_edit.lua` ports the surround/list bindings from the
Obsidian vimrc (`/mnt/d/obsidian_notes/default_vault/default/.obsidian.vimrc`)
so the same muscle memory works here. Every mapping is normal mode (WORD under
the cursor) *and* visual mode (the selection), and every one is a **toggle** —
pressing it again on already-wrapped text strips the delimiters.

The normal-mode target is `iW`, not `iw`: punctuation attached to the word goes
*inside* the wrap, so `` ` `` on `--word` gives `` `--word` `` rather than
``--`word` ``, and `foo.bar()` wraps whole. The cost is that a WORD also
swallows the delimiters of an *existing* wrap, so the toggle peels a matching
leading/trailing pair back off the span before deciding whether it is wrapped
(`shrink_wrapped`; `toggle_link` does the same for the `[text](url)` shape).

| key | does | overrides |
| --- | --- | --- |
| `~` | `~~strikethrough~~` | builtin `~` toggle-case (`g~` unaffected) |
| `` ` `` | `` `code` `` | builtin `` ` `` jump-to-mark prefix |
| `"` | `"quoted"` | builtin `"` register prefix |
| `'` | `'quoted'` | builtin `'` jump-to-mark prefix |
| `<leader>q` | `"quoted"` | — (leader-side alias for `"`) |
| `<leader>c` | `` `code` `` **in prose filetypes only** | Comment.nvim's visual line-comment toggle, in those buffers only |
| `<leader>l` | `[text](url)` **in prose filetypes only**, cursor lands in the parens in insert mode | the `<leader>l…` prefix (`la` Copilot, `lr` Copilot Chat, `le` LspEnable), in those buffers only |
| `gb` | toggle `- ` bullet list | Comment.nvim's blockwise-comment operator (`gb`/`gbc`); `<leader>C` still block comments |

**These overrides were a deliberate choice, made with the costs stated** —
matching the Obsidian keys exactly was worth more than the builtins they
displace. Don't "fix" them into a `<leader>` namespace. Two consequences are
load-bearing and easy to mistake for bugs:

- **There is no jump-to-mark key left.** Both `` ` `` and `'` are taken. `m`
  still sets marks and `:marks` still lists them; jumping needs `:normal!` or a
  new binding.
- **Typing a register prefix by hand no longer works** (`"ayy`, `"+p`). The
  explicit maps cover the cases that matter: `<leader>Y`/`<leader>P` for the
  system clipboard, `<leader>p`/`<leader>D` for the black hole.

`<leader>c` and `<leader>l` are the two scoped exceptions: line-commenting is
worth more in code than a code-inline wrap, and LSP/Copilot are not markdown
concerns, so inside a prose buffer `<leader>la`/`<leader>lr`/`<leader>le` are
simply unreachable — an accepted cost, not an oversight. Both are buffer-local,
attached by a `FileType` autocmd matching `*` — not the prose list — so that a
buffer whose filetype *changes away* from markdown gets the maps removed again;
a buffer-local map set once would otherwise outlive the filetype that justified
it.

Implementation notes: the visual-mode path escapes out of visual mode first,
because `'<`/`'>` are only published on leaving it; `'>` sits on the *first*
byte of the last character, so it's extended with `vim.str_utf_end` to cover
multibyte. Edits always apply the trailing delimiter before the leading one, so
the start column stays valid. A mixed bullet selection normalises to
all-bullets; only an all-bullet run is stripped.

`<S-BS>` / `<C-BS>` are mapped to `<C-u>` alongside `<leader><BS>`, but most
terminals (Windows Terminal included) send a plain `<BS>` for these, so they may
never fire. `<leader><BS>` stays the reliable page-up.

## yank history (`<C-p>` / `:Yanks`)

There is **one** yank history, it is global, and it is capped at the **last 15
entries**: every yank in every nvim — and every `dd`, `x` and `cw`, they are all
yanks — is appended to `~/.local/share/nvim/yanks.jsonl`, and every nvim reads
that same file. One way in, in normal, insert *and* terminal mode:

- **`<C-p>`**, or **`:Yanks`** (`after/plugin/yanks.lua`) — the history as an
  ordinary buffer in a split below (`:Yanks!` for a vsplit on the right). `<CR>`
  pastes the entry under the cursor back into the window you came from and
  closes: at the cursor in a buffer, into the shell's stdin in a terminal, with
  insert mode resumed if that is where you pressed the key. `p`/`P` do the same
  after/before the cursor, `d` deletes the entry from the history (everywhere —
  it is the shared store), `R` refreshes, `q` closes. The unnamed register is
  loaded too, so a following `p` repeats the paste.

The buffer is for reading the history, comparing two entries, or taking three
lines out of the middle of one: it renders the entries' text **verbatim** with
headers in between, precisely so that `/`, visual mode and `yy` work on it. One
buffer, reused — a second `:Yanks` refreshes it rather than opening another
window onto a stale copy. There used to be a telescope picker over the same
history on `<C-p>`; the buffer won, and it was removed along with neoclip.

**The store is `lua/shared/yank_store.lua`, and it is an append-only JSON-lines
log** — no plugin, no sqlite. That shape is the whole design, and it comes from
what replaced it: neoclip's store is a sqlite table, and `continuous_sync` (what
made its history global across *concurrently running* nvims, rather than a db
read once at startup and written once on `VimLeavePre`) pushes by *deleting and
reinserting the entire table on every yank*. At the 200-entry history it ran,
that is 200 rows rewritten through a C extension before the cursor moves, and it
was felt as lag while editing.

- **Recording is one `open(O_APPEND)` + one `write` + one `close`** of a few
  hundred bytes — the cost does not grow with the history. Measured at ~0.03 ms.
- **Reading** parses the file backwards, keeping the newest 15 and skipping
  duplicates (so re-yanking an old entry moves it to the front). Reads happen
  when `:Yanks` opens, not while editing, and the result is cached against the
  file's size+mtime — which is also what makes another nvim's writes show up.
- **Compaction** rewrites the log down to those 15 entries once it passes
  128 KiB, via a temp file and `rename`. The rename is atomic, so a reader never
  sees half a history; entries another nvim appended between the read and the
  rename are lost, which is the one race here and is worth the simplicity.
- One entry per line is also why a **truncated last line** (a crash mid-write)
  is skipped rather than poisoning the file. A single yank over 1 MiB is not
  recorded: 15 of those would be the store.

**Pasting into a terminal goes through `nvim_put` on the terminal buffer, not a
`chan_send` on its channel**, and the difference is not cosmetic: nvim_put wraps
the text in **bracketed paste** when the program on the other end asked for it
(DECSET 2004) and sends it raw when it did not. This terminal holds tmux, a
shell, and usually an *inner* nvim, and raw text arrives there as *keystrokes* —
pasting `class Duh()` into an inner nvim sitting in normal mode runs `c`, `l`
(change-a-character), inserts the rest, and most of the yank is gone with the
buffer damaged. Bracketed paste is how a program is told "this is text, not
typing". Verified through the real chain, tmux included: tmux forwards mode 2004
from the pane's application to its client, so the outer nvim sees it. zsh
honours it too, which also stops it executing every line but the last of a
multi-line paste. A program that never asked for it (`cat`) still gets raw text.

## clickable paths and URLs (`<CR>` in normal mode)

`lua/shared/open_under_cursor.lua` makes whatever is under the cursor
followable with `<CR>`, in **any** buffer and in a **terminal buffer's normal
mode** too, which is where it earns its keep — a stack trace, a `grep` hit, a
build log naming a pdf it just wrote.

| under the cursor | `<CR>` does |
| --- | --- |
| a URL (or a bare `www.…`) | `~/bin/open-url` → Firefox on the Windows side |
| a text file | opens it in a **new tab** (focused if already open) |
| `file:12` / `file:12:5` | the same, on that line and column |
| a directory | a new tab, netrw |
| a pdf/image/office/archive/binary | `explorer.exe /select,` — the containing folder, with the file selected |

**`<CR>` opens a tab; `gf` still opens in place.** That is the whole reason the
key is `<CR>` and not a remap of `gf`: following a path should never cost you
the window you were reading, which is the same argument `nv` and `:GitReview`
make. `gx` and `<leader>gf` are now thin callers of this module — one detector,
three destinations (browser / this nvim / a new Windows Terminal nvim).

Things worth knowing:

- **Nothing under the cursor falls through to the builtin `<CR>`**, so the key
  is not lost; `quickfix` and `prompt` buffers are skipped outright, since
  `<CR>` there is a buffer default rather than a mapping and would otherwise be
  shadowed. Every buffer-local `<CR>` in this config — netrw, `:Yanks`,
  `:GitReview`, `nvfuzzy`, markdown tables, cmp — shadows this map on its own
  and needed no changes.
- **A path only counts if it exists on disk.** There is no "did you mean";
  prose with a dot in it is left alone and gets the builtin `<CR>`.
- **In a terminal, relative paths resolve against the *shell's* cwd** — nvim's
  cwd is the wrong answer for a shell that has `cd`'d, and `f`/`fd`/`grep` all
  print relative paths. **Getting there needs tmux**, and that is the whole
  subtlety: the `:terminal` here runs `tmux attach-session`, and a tmux pane's
  shell is a child of the tmux **server**, not of the client nvim spawned — so
  `/proc/<terminal_job_pid>/cwd` is nvim's *own* cwd and the pane's shell is
  nowhere in that process tree at all. (This is exactly the bug the first cut
  shipped with: every relative path in a terminal silently failed to resolve
  and `<CR>` just moved the cursor down a line.)
  So tmux is asked: `list-clients` is matched on **client pid** — the job pid,
  or a descendant of it, since the client may sit under a wrapper — rather than
  on this config's `nvt-<pid>-<n>` session names, which keeps it working for
  any tmux. What is taken from tmux is the pane's **pid**, not its path:
  `#{pane_current_path}` is cached and only refreshed while a client is
  redrawing, so it can lag a `cd` indefinitely (reproduced), while
  `/proc/<pane pid>/cwd` is always live. It stays as a fallback.
  From that pid — or from the job pid directly, with no tmux — the walk goes
  *down* through single children, because the pane usually holds zsh → (an
  inner nvim), and it is the innermost one whose cwd you are looking at.
- **A scratch buffer showing a terminal's output borrows that terminal's cwd.**
  The `<C-e>` tmux scrollback is a `nofile` buffer with no job of its own, but
  it is full of the same relative paths the pane printed, so it carries
  `b:open_under_cursor_term_buf` pointing at the terminal it was captured from.
  That is a buffer *number*, not a path, deliberately: it is resolved on every
  `<CR>`, so a `cd` in the pane after the capture is still followed.
  `b:open_under_cursor_cwd` is the blunt version for anything that simply knows
  its directory. Note that **the terminal nvim itself is running in is the
  wrong answer here** and cannot be used instead: that is the outer shell, whose
  cwd is wherever nvim was launched, while the paths on screen came from the
  tmux pane two levels further in.
- Resolution order is the buffer's own directory, then nvim's cwd, then the
  file's directory; `~`, `$VARs`, `file://` URLs and **Windows paths**
  (`D:\obsidian_notes`, via `wslpath -u`) all resolve.
- A **quoted or bracketed span wins over the bare token** — `"my docs/a.md"`,
  `[text](path)`, `<path>` — which is how a path with a space in it works at
  all. It is only taken when it contains a `/` or `://`, so ordinary quoted
  prose is not mistaken for a path.
- Text-or-not is an **extension list first, then a NUL sniff** of the first
  KiB. The list exists so a 2 GB `.mkv` is never read, and it also holds a few
  files that *are* text but that you want the OS handler for anyway (`.svg`,
  `.drawio`).

The shell half is `explorer [path]` in `~/dotfiles/zshrc` (alias `ex`): the
same "select the file in its folder" behaviour from the command line. It
returns 0 explicitly because `explorer.exe` exits 1 even on success.

Plugins for this exist (pathfinder.nvim, gx.nvim, url-open) and none was used:
every one of them ends at `vim.ui.open`, and the entire question here is what
happens *after* that — Firefox through PowerShell, `wslpath`, `explorer.exe
/select` — which is WSL-specific and already written in this config.

## fuzzy file open (`nv <pattern>` from the shell)

`nv api` in the shell opens nvim **immediately** and searches from there;
`lua/shared/nvfuzzy.lua` is the editor half, and the shell half is
`~/dotfiles/zshrc.nv` (`nv`, `nvf`, `f`; `nv --help`). Nothing is searched
before nvim starts — that ordering is the whole command. The pattern arrives
in `NVFUZZY_PATTERN` / `NVFUZZY_TOP` / `NVFUZZY_FIRST` / `NVFUZZY_DIRS` and
the walk runs as a job, matching **file names**, case-insensitively, 50
levels down (`-t`: 1 level), hidden files included, `.git` and gitignored
paths out.

**The pattern is a subsequence, not a substring**: its characters have to
appear in order but not together, so `nv evenapi` finds
`LinkedInEventsApi.kt`. It is expanded to a regex (`e.*v.*e.*n.*a.*p.*i`) and
run by fd's own engine rather than filtered afterwards in Lua. Only a plain
pattern is expanded — anything containing a character that is not a letter,
digit, `_`, `.` or `-` goes to fd verbatim, which is the escape hatch when you
want a real regex.

What arrives is split in two, and the split is the point:

- **The best 5 hits become tabs 1–5**, left of the results tab, and **only the
  first one takes the cursor** — everything after it lands behind you. A
  search hit yanking you out of the file you are reading is what this avoids;
  landing on the best hit is what you asked for. The set is *settled* when the
  search ends (see below), because until then there is no such thing as "the
  best five".
- **Every hit is listed in a results buffer**, which is always the **last**
  tab: plain paths, an ordinary scratch buffer. Same argument as `:Yanks` and
  `:GitReview` — `/`, `n`, visual mode, `yy`, `gf` and marks all work because
  it is text. `<CR>` opens the path under the cursor in a tab (a directory
  opens as netrw, and a file already open just gets focused, via
  `shared.tab_utils`); `R` re-runs, `q` closes.
- **With no hits** the buffer says so and lists two levels of the directory
  you ran in — "then what *is* here?" is the next question either way.

### breadth-first, without a timer

fd walks depth-first, so the first things it prints are whatever directory it
descended into first — `init.lua` at the root losing to ten files four levels
down. **The search therefore runs in depth bands** — `[1,1]`, `[2,2]`,
`[3,50]` — spawned at once but **released in order**: a band's hits are held
until every shallower band has *exited*. What reaches you is breadth-first.

- **The gate is a process exit, not a clock.** In an ordinary repo the deep
  band is released after ~50 ms, sooner than any timer worth setting; in a
  huge tree it waits exactly as long as the shallow sweeps actually take. An
  earlier version used a fixed 150 ms grace window instead — this is both
  faster and correctly ordered.
- **The bands stop at 2 because that is where the cost/benefit turns.** Each
  band is one more walk down to its depth. Measured on a pathological home
  directory (where a full 50-level walk does not finish inside a minute) band
  1 costs 0.33 s and band 2 costs 0.09 s; in an ordinary repo all of them are
  ~0.05 s. Two shallow bands buy correct ordering for the root and the level
  under it, which is where the file you meant almost always is. Depth 3 and
  below arrives in walk order.
- A band that was held long enough to queue hits up is **ranked before it is
  let out**, since by definition it is all in hand at once. The *listing* is
  always fully ranked and re-ranks as it grows.

**Banding cannot do the whole job**, and `settle_tabs` is the other half. Depth
is all a band knows: it cannot separate ten hits that all sit at depth 8, and a
subsequence loose enough to find `LinkedInEventsApi.kt` from `evenapi` also
drags in files that match by accident. So the tabs that go up during the search
are the first five *released*, not the best five — and when the search ends the
set settles onto the real ranking: better hits are opened, the tabs they
displace are closed, the tabline is sorted best-first, and if you are still on
the tab `nv` dropped you on (so you were waiting for it) you are moved to the
best hit. **The tab you are in is never closed**, nor is one whose buffer you
have edited, so the set can end up one or two over the limit — that is the
right way to be wrong. Having navigated anywhere at all is enough to be left
alone entirely.

Note that this is also why `open_hit_tab` does **not** use
`tab_utils.focus_if_open` the way telescope and netrw do: that helper jumps to
the tab it finds, which is right when a keypress asked for the file and wrong
for a background hit — it was the one remaining way a search result could yank
you out of what you were reading.

Things worth knowing:

- The rank is a tier for *how* it matched — exact basename > stem > prefix >
  contiguous substring > subsequence — then how **tightly** (the span of the
  tightest run of the name containing the pattern; a contiguous match spans
  exactly the pattern's length), then the shallowest path, then the shorter
  name. The tightening is greedy forward to find where the match can end, then
  greedy backward from there for the latest start, so `evenapi` scores against
  the `eventsApi` at the end of `LinkedInEventsApi.kt` and not the `e` back in
  "Linked". **The same score is implemented in awk in `~/dotfiles/zshrc.nv`**
  for `f -f`; the two must agree, since `f -f api` and `nv -f api` should open
  the same file. `-f` opens the top of that and
  nothing else, stopping at the first *released* hit — which is from the
  shallowest band with anything in it, so it does not wait out a 50-level
  walk.
- fd (`fdfind`) matches the basename by default and its pattern is an
  unanchored regex, so a plain `api` already means `.*api.*` with no wrapping.
  `find` is the fallback when fd is missing; `-iname` is a glob, so the same
  subsequence falls out of `*e*v*e*n*a*p*i*`. Both take
  `--min-depth`/`-mindepth`, which is what makes the banding work.
- Hard-stopped at 2000 hits (`MAX_HITS`) — a pattern that loose is a mistake,
  not a search — and the header says when that happened.
- **An explicit path is a path, not a pattern.** The shell function opens an
  argument that exists on disk, or that contains a `/`, directly — so
  `nv src/new.lua` still creates a new file, and bare `nv` still opens netrw
  on the current directory.

`f` is the same search printed to the shell instead, and it streams: fd's
output is read line by line and echoed as it is found (measured: first line at
0.5 s of a 2.4 s walk), which is also why `f` cannot rank — only `f -f`, which
has to see everything, does. It is fed by process substitution rather than a
pipeline because zsh runs *every* stage of a pipeline in a subshell, so piping
into the loop would print eagerly but lose the count. The suspended-job helper
that used to own the name `f` is now `fp` / `fplist` (`~/dotfiles/zshrc.jobs`).

## tab management (`<C-f>` chord)

`after/plugin/tabs.lua`. These used to hang off `<C-t>`, which was wrong:
`<C-t>` is the *terminal* chord (`<C-t>t` / `<C-t>T` open one) and `<C-b>` is
tmux's prefix inside it, so both belong to the terminal in the split next
door. `<C-f>` was free, and the builtin it displaces — page forward — is
already `<PageDown>`, `J` and `<C-d>` here.

`<C-f>` `o` only (close every other tab) · `x` close · `n` new · `b` telescope
picker · `m` move this split into its own tab (`<C-w>T`; it was `<C-t>o`,
before `o` was needed for "only") · `s`/`v` fold the previous tab into a split
· `<`/`>` move this tab along the tabline.

**`<Home>`/`<End>` walk the tabline** — left and right as drawn, not vim's
numbering-by-recency. They were `<PageUp>`/`<PageDown>` first, and that was the
wrong key to spend: `J`/`K` are non-recursive maps *onto* `<PageDown>`/`<PageUp>`,
so taking those keys left the aliases pointing at a tab switch and paging with
`J`/`K` quietly became tab-walking. `<Home>`/`<End>` displace start- and
end-of-line, which are `0`/`^` and `$` here anyway. `gt`/`gT` stay reversed, as
`remap.lua` has them.

## git review (`:GitReview`)

`after/plugin/git_review.lua` renders a whole branch — the uncommitted changes
first, then the whole branch aggregated into one net diff, then every commit
with its message and its per-file diffs — as **one scratch markdown buffer**,
oldest commit first, and nothing else. It is the answer to reviewing by opening the
changed files one at a time, which loses both the order the work happened in
and the message explaining why.

Every review plugin in the ecosystem (diffview.nvim, octo.nvim,
gh-review.nvim, reviewthem.nvim, codereview.nvim) answers the same problem with
a **file tree plus a side-by-side pane**: a UI to drive, usually with its own
state directory and often a `gh` dependency. This answers it with a *document*
you read top to bottom. None of them is installed here; there are no git
plugins in this config at all.

**Being an ordinary buffer is the whole point** — the same argument as `:Yanks`
in `after/plugin/yanks.lua`. `/`, `n`, visual mode, `yy`, marks and folds work
because it is text, so there is nothing to learn.

- **Uncommitted work comes first**, split into `staged` / `unstaged` /
  `untracked` and labelled per file, because it is the part still in your hands:
  everything below it is history and cannot be edited. Staged and unstaged are
  kept apart rather than merged into one `git diff HEAD` — when you are about to
  commit, which half a hunk is in is the thing you are checking. An untracked
  file is diffed against `/dev/null` so it renders as all `+`; one over 128 KiB
  is named and not shown, so a stray `node_modules` cannot become the review.
- **`## All changes` is the same work with the commits taken out**: the range's
  start diffed against the working tree (untracked files included), one `###`
  section per file. It sits *above* the commit sections because it is what a
  reviewer reads first — the commits answer *how did this happen*, this answers
  *what does it come to*, which is the shape you sign off on and the one a
  series with a fix-up commit in it hides. It is omitted when there is no range
  to aggregate over, since the uncommitted section would then be the whole of
  it.
- No argument on a feature branch is the intended use: everything since the
  merge base with the base branch (`origin/HEAD`'s target, else the first of
  `main`/`master`/`trunk`/`develop` that exists). **On the base branch itself it
  refuses and asks for a depth** rather than guessing — how far down `main`
  counts as "this work" is not something the command can know. That refusal is
  *soft*: with a dirty tree it still renders the uncommitted section and prints
  the message as a note, since "what have I changed" is the usual reason to run
  this on `main` at all.
- `:GitReview 10` (a depth), `:GitReview v1.2` / `<branch>` (a base to take the
  merge base with), `:GitReview a..b` (a range verbatim). `<Tab>` completes refs.
- `:GitReview!` opens a vsplit next to the code instead of a new tab.
- `<CR>` opens the file at the diff line under the cursor, in the window
  `:GitReview` was called from. `]]`/`[[` move by commit, `R` refreshes, `q`
  closes, `zM` folds to one line per commit (headings drive the fold expr).

Things worth knowing:

- **The diffs are ` ```diff ` fenced so markdown's treesitter injection colours
  them**, which is why the output is markdown rather than a bespoke filetype —
  +/- highlighting costs nothing here. The fence is grown to one backtick longer
  than the longest run inside the chunk, because a diff of a markdown file
  contains fences of its own and a plain ` ``` ` would end the block mid-patch.
- **Merges are excluded** (`--no-merges`): `git show` prints no diff for one
  anyway, and on a feature branch they are merges *from* the base bringing in
  other people's work, which is not what is under review. The header says so.
- One `git show` per commit, split on `diff --git` lines here, rather than a
  `git show -- <file>` per file — a 40-file commit is one process, not forty.
  `index`/`---`/`+++` lines are dropped as noise (the `###` heading already
  names the file, with its +/- counts); `new file`/`deleted`/`rename`/`Binary`
  lines are kept, since a hunk cannot say those.
- `<CR>` works off an index built **while rendering**: each emitted line that
  exists on the `+` side of a hunk records its new-file line number, counted
  from the `@@` header. Nothing is re-parsed on the jump, so the mapping cannot
  drift from what is on screen.
- One buffer, reused (again as `:Yanks`) — a second `:GitReview` refreshes it
  rather than stacking windows onto stale copies of a branch that moves.

## autosave

`after/plugin/autosave.lua` writes modified buffers on `InsertLeave`,
`TextChanged`, `FocusLost` and `BufLeave`.

**The scope is deliberately narrow: only buffers already backed by a file that
exists on disk.** A `[No Name]` buffer, a terminal, help, quickfix, a plugin
scratch buffer and a readonly file are all skipped. Autosave must never be the
thing that decides where a file lives — that is the user's `:w path` to make.

The write is `pcall`ed: a `BufWritePre` autocmd that errors (a formatter that
cannot parse half-typed code) must not raise a popup on every keystroke. The
buffer simply stays modified and the next trigger retries.

**Autosave never resolves a conflict.** If the file on disk is not the one the
buffer was last in sync with, the write is refused, the buffer stays modified,
and a notification names the two ways out: `:w!` to overwrite disk, `:e!` to
discard the buffer and reload. Either one un-pauses autosave (`BufWritePost` /
`BufReadPost` re-stamp the buffer as in sync). `:AutoSaveStatus` reports a
standing pause.

This is not guarding against a silent clobber — vim already refuses to
overwrite a changed file. It is guarding against *how* it refuses: a blocking
`Do you really want to write to it (y/n)?` dialog, which `silent` does not
suppress, raised in the middle of typing. That prompt is right for a deliberate
`:w` and wrong for a keystroke-driven one, so the gate answers "no" by never
reaching the write.

Two independent detectors, and both are needed:

- **A latch on `FileChangedShell`** — vim's own detection, the same event that
  raises the FILE CHANGED ON DISK bar (`lua/shared/file_changed_bar.lua`, which
  owns `v:fcs_choice`), so the bar and the gate can never disagree. It **must**
  be latched: vim re-stamps the buffer's mtime as it fires, so the event is
  delivered exactly **once** per external change — polling it a second time
  reports all-clear on a conflict that is still unresolved.
- **A stamp of our own** — disk mtime to the nanosecond, plus size. Nanoseconds
  because an external write landing in the same second as ours is exactly the
  race worth catching. This one doesn't care when the last `:checktime` ran.

**The same file open in several tabs is not a conflict and cannot be one.** Vim
identifies buffers by (device, inode), not by path, so one file opened in ten
tabs — absolute path, relative path, through a symlink, through a hard link —
is one single buffer every time (verified). The tabs share one set of contents
and cannot diverge. The check that *is* there covers the one case that does
produce two buffers on one path: the file a buffer was opened from gets
**replaced** (a `git checkout` swapping the inode) and the path is opened
again. It costs a stat per open buffer on a per-keystroke event, so the answer
is cached and recomputed only when the buffer list changes.

`:AutoSaveToggle` / `:AutoSaveStatus`.

## AI completion (Copilot)

GitHub Copilot is the only AI completion/chat engine in this config. (A
Claude engine via minuet-ai.nvim existed earlier but was removed — it needed
paid Anthropic API credits not covered by a Pro plan, while Copilot is free
here via the Student Developer Pack.)

**The approach — a "wrapper script" over the underlying plugins:**

- **Off by default, everywhere.** `lua/shared/copilot.lua` sets
  `filetypes = { ['*'] = false }` and never calls `require('copilot').setup()`
  until a project opts in — so a random repo you `cd` into never talks to
  Copilot's servers.
- **Opt-in is per-project, not per-session.** `<leader>la`
  (`after/plugin/copilot.lua`) writes/trusts/sources a `.nvim.lua` at the
  project root (via `exrc`, `lua/shared/set.lua`) that force-attaches Copilot
  for every filetype in that project, from then on, in this session and
  future ones. `.nvim.lua` must stay in the project's own `.gitignore` — it's
  local machine config, not something to commit.
- **Sensitive files are excluded unconditionally.** `lua/shared/copilot.lua`'s
  `is_sensitive()` checks buffer names against patterns (`.env`, `secret`,
  `id_rsa`, `.zshrc.secrets`, etc.) and blocks both inline suggestions and the
  chat/refactor keymap for matches, regardless of project opt-in.
- **No secrets file for Copilot.** Auth is GitHub's OAuth device-code flow
  (`:Copilot auth`), and the resulting token is cached under
  `~/.config/github-copilot/` by the plugin itself — nothing to paste into
  `~/.zshrc.secrets`. See the comment there for the full explanation.
- **Region refactor (`after/plugin/copilot_chat.lua`, CopilotChat.nvim).**
  Select code in visual mode, press `<leader>lr`, type what you want changed
  into the pre-filled `:CopilotChat ` command line, hit `<CR>`. The reply
  lands in a split with a diff for the selection; `<C-y>` there applies it
  back over your original code (CopilotChat's default `accept_diff` mapping).
  This is the closest equivalent to VS Code's inline chat (Ctrl+I) available
  in Neovim — Copilot's own completion plugin has no such feature, hence the
  separate plugin. Lazy-loaded on first `:CopilotChat*` use.
- **Copilot Free/Student "auto model" patch (`patches/copilotchat-auto-model.patch`).**
  GitHub restricted Copilot Free/Student plans to "auto" model selection only
  (2026-06-24). Upstream CopilotChat.nvim (as pinned in `lazy-lock.json`)
  can't fully drive that: the model list is filtered to
  `model_picker_enabled` (false for every real model on these accounts, so
  only a synthetic "Auto" entry survives), and the model "auto" resolves to
  server-side needs a `Copilot-Session-Token` header the client never
  captures — without it every chat request 400s with `model_not_supported`,
  even inline ghost-text completion works fine. Confirmed via GitHub search
  this is a known, actively-being-worked-on upstream bug (unmerged PRs
  [#1575](https://github.com/CopilotC-Nvim/CopilotChat.nvim/pull/1575) and
  [#1577](https://github.com/CopilotC-Nvim/CopilotChat.nvim/pull/1577); a
  third, [#1578](https://github.com/CopilotC-Nvim/CopilotChat.nvim/pull/1578),
  was closed unmerged with real correctness issues per review — not used
  here). The patch combines #1577's model-list/fallback fix with #1575's
  session-token forwarding, applied automatically via the plugin spec's
  `build` step in `lua/shared/lazy.lua` (idempotent — skips if already
  applied, warns instead of erroring if upstream changes enough that it no
  longer applies cleanly). Verified end-to-end with real chat requests
  against a live Student-plan account. Safe to delete once this lands
  upstream and gets pulled in by a `lazy-lock.json` bump.

See `:Cheatsheet` (`<leader>?`) for the full keymap list.

## WSL notes

- `clip.exe` used for clipboard in netrw (`yp` copies path)
- `wt.exe` / `wsl.exe` used for opening files in new Windows Terminal window (`<leader>gf`)
- `wslpath` converts between WSL and Windows paths
- `~/bin/open-url` used for URLs (avoids `cmd.exe` `&` parsing bug)
