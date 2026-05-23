vim.cmd('colorscheme rose-pine')

vim.api.nvim_set_hl(0, "Normal", { bg = "none" })
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "none" })

vim.api.nvim_set_hl(0, "Search",    { fg = "#1f1d2e", bg = "#f6c177", bold = true })
vim.api.nvim_set_hl(0, "IncSearch", { fg = "#1f1d2e", bg = "#eb6f92", bold = true })
vim.api.nvim_set_hl(0, "CurSearch", { fg = "#1f1d2e", bg = "#eb6f92", bold = true })
