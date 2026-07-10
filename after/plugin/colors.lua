vim.cmd('colorscheme rose-pine')

vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })

vim.api.nvim_set_hl(0, "Search",    { fg = "#1f1d2e", bg = "#f6c177", bold = true })
vim.api.nvim_set_hl(0, "IncSearch", { fg = "#1f1d2e", bg = "#eb6f92", bold = true })
vim.api.nvim_set_hl(0, "CurSearch", { fg = "#1f1d2e", bg = "#eb6f92", bold = true })

-- Terminal mode style palette (adjust hex values here to restyle; cursors are in set.lua)
-- NvimTerminalNVisual: Visual selection in terminal-normal (nt) mode  → orange-y
-- NvimTerminalTVisual: Visual selection in terminal-insert (t)  mode  → green-y
vim.api.nvim_set_hl(0, "NvimTerminalNVisual", { bg = "#3d2000" })  -- dark orange
vim.api.nvim_set_hl(0, "NvimTerminalTVisual", { bg = "#0d3a0d" })  -- dark green

-- Netrw dotfiles/dotdirs: shown muted in netrw tree (rose-pine muted)
vim.api.nvim_set_hl(0, "NetrwDotFile", { fg = "#6e6a86" })           -- dotfiles
vim.api.nvim_set_hl(0, "NetrwDotDir",  { fg = "#6e6a86", bold = true }) -- dotdirs (bold preserved)

-- Generic cross-filetype highlights (after/plugin/custom_highlights.lua):
-- applied via matchadd() so they work even in plain-text buffers with no syntax file.
vim.api.nvim_set_hl(0, "HlQuotedString", { link = "String" })   -- "quoted", 'quoted', `quoted`
vim.api.nvim_set_hl(0, "HlParenText",    { link = "Special" })  -- (parenthesised text)
vim.api.nvim_set_hl(0, "HlEscapeSequence", { fg = "#f6c177", bold = true }) -- \n / \t (rose-pine gold)
vim.api.nvim_set_hl(0, "HlSlashCommand", { fg = "#9ccfd8", bold = true }) -- /command words (rose-pine foam)
vim.api.nvim_set_hl(0, "HlFlagCommand",  { fg = "#c4a7e7", bold = true }) -- -command / --command flags (rose-pine iris)
vim.api.nvim_set_hl(0, "HlGrayComment",  { fg = "#6e6a86" })    -- whole-line # / // comments (rose-pine muted)
vim.api.nvim_set_hl(0, "HlTodoMarker",  { fg = "#31748f", bold = true })       -- TODO (rose-pine pine, bold blue)
vim.api.nvim_set_hl(0, "HlFixmeMarker", { fg = "#eb6f92", bold = true })       -- FIXME (rose-pine love, bold red)
vim.api.nvim_set_hl(0, "HlNoteMarker",  { fg = "#f6c177" })                    -- NOTE (rose-pine gold, non-bold yellow)
vim.api.nvim_set_hl(0, "HlBugMarker",   { fg = "#f59e0b", bold = true })       -- BUG (amber/orange, bold)

-- Inner nvim ($NVIM set = launched from inside another nvim's terminal buffer):
-- override Visual + Cursor globally so editing colours are green.
-- WHY hl group here, not OSC 12: Cursor hl applies to n/i/v modes (normal editing).
-- OSC 12 is only needed for nt mode where Cursor hl has no effect (see set.lua).
if vim.env.NVIM then
  vim.api.nvim_set_hl(0, "Visual", { bg = "#0d3a0d" })
  vim.api.nvim_set_hl(0, "Cursor", { fg = "#000000", bg = "#39ff14" })
end
