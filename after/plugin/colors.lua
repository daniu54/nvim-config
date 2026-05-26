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

-- Inner nvim ($NVIM set = launched from inside another nvim's terminal buffer):
-- override Visual + Cursor globally so editing colours are green.
-- WHY hl group here, not OSC 12: Cursor hl applies to n/i/v modes (normal editing).
-- OSC 12 is only needed for nt mode where Cursor hl has no effect (see set.lua).
if vim.env.NVIM then
  vim.api.nvim_set_hl(0, "Visual", { bg = "#0d3a0d" })
  vim.api.nvim_set_hl(0, "Cursor", { fg = "#000000", bg = "#39ff14" })
end
