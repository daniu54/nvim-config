# nvim config — CLAUDE.md

Instructions and context for Claude Code when working in this repository.

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
after/plugin/
  colors.lua                — colorscheme (rose-pine)
  conform.lua               — formatter config
  harpoon.lua               — harpoon2 config
  telescope.lua             — telescope config
  cmp.lua                   — nvim-cmp completion (buffer + path + lsp)
  lsp.lua                   — on-demand pyright LSP via :LspEnable
plugin/
  packer_compiled.lua       — gitignored, stale packer artifact
```

## installed plugins

Defined in `lua/shared/packer.lua`:

| Plugin | Purpose |
|--------|---------|
| rose-pine | colorscheme |
| telescope.nvim | fuzzy finder |
| harpoon (harpoon2 branch) | file bookmarks |
| nvim-cmp | completion engine |
| Comment.nvim | gcc/gc commenting |
| nvim-treesitter | syntax highlighting + folding |
| conform.nvim | formatting |
| mapx.nvim | neater keymap definitions |
| lsp-zero.nvim (v1.x) | LSP helpers (Mason + lspconfig bundled) |
| hrsh7th/cmp-* | completion sources (buffer, path, nvim-lsp, nvim-lua) |
| LuaSnip + friendly-snippets | snippets (available but not heavily used) |

## completion setup

`after/plugin/cmp.lua` — nvim-cmp configured with:
- **buffer source** — words from open buffers (always active, fast)
- **path source** — filesystem paths (always active)
- **nvim_lsp source** — language-aware completions (only active when LSP is attached)

Keybindings:
- `<Tab>` / `<S-Tab>` — navigate completion menu
- `<CR>` — confirm selected item
- `<C-e>` — close menu
- `<C-Space>` — manually trigger menu

## LSP (on-demand)

`after/plugin/lsp.lua` — pyright is NOT auto-started (to keep file-open fast).

To enable:
1. Install pyright once: `:MasonInstall pyright`
2. In a Python file: `:LspEnable` or `<leader>le`

This starts pyright for the current session and enables language-aware completions via cmp.

## keymaps (notable)

Defined in `lua/shared/remap.lua`:

| Key | Action |
|-----|--------|
| `<leader>pv` | open netrw file explorer |
| `<leader>le` | enable pyright LSP |
| `H` / `L` | previous / next buffer |
| `gx` | open URL under cursor in Firefox (WSL-aware) |
| `<leader>gf` | open file path under cursor in new nvim window |
| `<leader>s` | search-replace word under cursor |
| `<leader>Y` / `<leader>P` | yank/paste to/from system clipboard |
| `<BS>` / `<leader><BS>` | fast scroll down/up (`<C-d>` / `<C-u>`) |
| `<leader><Esc>` | exit terminal mode |

## folding

Uses treesitter-based folding (`foldexpr = v:lua.vim.treesitter.foldexpr()`).
Set per-buffer via `FileType` autocmd in `set.lua`. All folds start open (`foldlevelstart = 99`).

## WSL notes

- `clip.exe` used for clipboard in netrw (`yp` copies path)
- `wt.exe` / `wsl.exe` used for opening files in new Windows Terminal window (`<leader>gf`)
- `wslpath` converts between WSL and Windows paths
- `~/bin/open-url` used for URLs (avoids `cmd.exe` `&` parsing bug)

## .gitignore

```
plugin/packer_compiled.lua
.netrwhist
lazy-lock.json
```

`lazy-lock.json` is gitignored (intentional — not pinning plugin versions).
