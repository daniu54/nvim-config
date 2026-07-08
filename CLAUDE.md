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
