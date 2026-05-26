vim.cmd('colorscheme rose-pine')

vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })

vim.api.nvim_set_hl(0, "Search",    { fg = "#1f1d2e", bg = "#f6c177", bold = true })
vim.api.nvim_set_hl(0, "IncSearch", { fg = "#1f1d2e", bg = "#eb6f92", bold = true })
vim.api.nvim_set_hl(0, "CurSearch", { fg = "#1f1d2e", bg = "#eb6f92", bold = true })

-- Terminal mode styles (adjust hex values here to restyle)
-- NvimTerminalCursor: applied via OSC 12 in set.lua (can't be an hl group — see comment there)
-- NvimTerminalVisual: applied as a winhighlight override on all terminal windows
vim.api.nvim_set_hl(0, "NvimTerminalVisual", { bg = "#1a3a1a" })  -- dark green
