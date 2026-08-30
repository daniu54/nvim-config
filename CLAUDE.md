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
lua/shared/
  init.lua                  — loads remap, set, packer, wt_colors
  lazy.lua                  — plugin definitions (lazy.nvim)
  remap.lua                 — keymaps
  set.lua                   — vim options
  wt_colors.lua             — Windows Terminal background color sync
  copilot.lua               — shared Copilot infra (bootstrap, sensitive-file check, opt-in helper, <Right>/<S-Right>)
after/plugin/
  autosave.lua              — autosave file-backed buffers (:AutoSaveToggle)
  markdown_convert.lua      — :ConvertToPdf/:ConvertToTex/:ConvertToWord via mdpdf
  markdown_table.lua        — Obsidian-style table editing (<Tab>/<CR> grow the table)
  multicursor.lua           — multiple cursors (<A-j>/<A-k>), multicursor.nvim
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

## markdown tables (ported from Obsidian)

`after/plugin/markdown_table.lua` ports the Obsidian tables plugin's three
behaviours: typing `| name | age |` and pressing `<CR>` (or `<Tab>`) writes the
`| --- | --- |` row and makes it a real table; `<Tab>` moves right and *creates*
a column when there is none; `<CR>` moves to the next row, creating it, and on
an empty last row drops out of the table instead — that is the way out. Plus
`<A-h/l>` `<A-k/j>` insert a column/row, `<A-S-…>` move one, `<A-d>` deletes a
column, `<A-a>` cycles alignment, `<A-t>` inserts a fresh table, `:TableFormat`
reflows. The four row keys are shared with multiple cursors — see "multiple
cursors" below. Everything reflows on those keys and on `InsertLeave`.

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
so the same muscle memory works here. Every mapping is normal mode (word under
the cursor) *and* visual mode (the selection), and every one is a **toggle** —
pressing it again on already-wrapped text strips the delimiters.

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

## multiple cursors

`after/plugin/multicursor.lua` (multicursor.nvim, pinned in `lazy-lock.json`).
`<A-j>` / `<A-k>` drop another cursor on the line below / above; then use vim
exactly as with one cursor — `i`, `a`, `ciw`, `dd`, `.`, counts, motions,
registers, undo and completion all run at every cursor — and `<Esc>` collapses
back to one. Text typed in insert mode appears at the other cursors **when you
leave insert mode**, not keystroke by keystroke; that is the plugin's design,
not a bug.

| key | does |
| --- | --- |
| `<A-j>` / `<A-k>` | add a cursor below / above |
| `<A-S-j>` / `<A-S-k>` | skip a line — move on without leaving a cursor |
| `<A-n>` / `<A-N>` | cursor on the next / previous match of the word under the cursor (or the visual selection) — VS Code's `Ctrl+D` |
| `<A-s>` / `<A-S>` | skip that match instead of taking it |
| `<A-m>` | a cursor on every match in the buffer |
| `<A-q>` | freeze the extra cursors (only the main one moves) / unfreeze |
| `<A-g>` | restore the cursors just cleared |
| `<C-LeftMouse>` (+drag) | add/remove a cursor by clicking |
| `<A-,>` / `<A-.>` | make the previous / next cursor the main one — *only while cursors exist* |
| `<A-x>` | delete the main cursor — *only while cursors exist* |
| `<Esc>` | unfreeze if frozen, else collapse to one cursor — *only while cursors exist* |

The last three live in a **keymap layer**: the plugin maps them only while
cursors exist, which is what lets `<Esc>` stay `<Esc>` the rest of the time.

**Not vim-visual-multi**, the older and better-known plugin: it runs its own
modal layer with its own meaning for most keys, and "a multi-cursor is just a
cursor" was the point here.

**The one collision is with the markdown table keys**, which own `<A-j>`,
`<A-k>`, `<A-S-j>` and `<A-S-k>` in markdown buffers. Rather than move either
set, `op()` in `after/plugin/markdown_table.lua` **falls through**: with the
cursor inside a table those keys insert and move rows, and anywhere else in the
file they add and skip cursors — the same arrangement the `<Tab>`/`<CR>`
handlers have with nvim-cmp. Falling through means *calling* multicursor
directly, never feeding `<A-j>` again: without remapping that finds no mapping
at all, and with remapping it lands straight back in the table map. The
remaining cost is that inside a table there is no way to add a cursor.

`mc.setup()` would also claim normal-mode `<C-i>` / `<C-o>` for a cursor-aware
jumplist, but only when *both* are unmapped, and here neither is: `<C-i>` comes
from nvim's own defaults and `<C-o>` is telescope's find-files. So the jumplist
keys are untouched (verified with `mapcheck`) — worth knowing if `<C-o>` is ever
freed up, since multicursor would then take both.

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
