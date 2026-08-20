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
- `/tableofcontents` — a table of contents right there, with no heading above
  it. `## Heading {.notoc}` keeps a section out of it (pdf/tex only — a Word
  TOC is built from heading styles).
- ```` ```mermaid ```` fenced blocks render as diagrams.
- **Cross-references** that jump in pdf/tex/docx. `[text](#my-section-title)`,
  `## Heading {#custom-id}`, or the section's name written out —
  `[text](#My Section Title)`. For a target that is not a heading, put
  `{#the-spot}` on a line of its own. Links work inside table cells. A link
  resolving to nothing is reported on stderr rather than silently dead.

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
