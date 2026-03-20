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

## WSL notes

- `clip.exe` used for clipboard in netrw (`yp` copies path)
- `wt.exe` / `wsl.exe` used for opening files in new Windows Terminal window (`<leader>gf`)
- `wslpath` converts between WSL and Windows paths
- `~/bin/open-url` used for URLs (avoids `cmd.exe` `&` parsing bug)
