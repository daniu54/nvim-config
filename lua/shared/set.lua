vim.api.nvim_command('set clipboard=unnamedplus')

vim.api.nvim_set_var('netrw_bufsettings', 'noma nomod nu nobl nowrap ro')

vim.api.nvim_create_autocmd("TermOpen", {
  pattern = "*",
  callback = function()
    vim.opt_local.number = true
    vim.opt_local.relativenumber = true
  end,
})

if vim.loop.os_uname().sysname == "Windows" then
	vim.api.nvim_exec('language en_US', true)
end

vim.opt.nu = true
vim.opt.relativenumber = true

vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.encoding = "utf8"
vim.opt.expandtab = true

vim.opt.smartindent = true

vim.g.editorconfig = false -- disable checking for a .editorconfig file

vim.opt.swapfile = false
vim.opt.backup = false

-- only works on linux? need correct handling 
-- vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir"

vim.opt.undofile = true

vim.opt.hlsearch = true -- hightlight search results
vim.opt.incsearch = true

vim.opt.termguicolors = true

vim.opt.scrolloff = 8
vim.opt.isfname:append("@-@")

vim.opt.fillchars = "eob: " -- hide tilde

-- Set completeopt to have a better completion experience
vim.opt.completeopt = 'menuone,noselect'

-- increase timeouts for slow command input
vim.opt.timeoutlen = 10000
vim.opt.ttimeoutlen = 100

vim.opt.title = true

-- folding (zc = close fold, zo = open fold)
-- must be set per-buffer via FileType so treesitter parser is attached first
vim.opt.foldlevelstart = 99  -- start with all folds open
vim.api.nvim_create_autocmd("FileType", {
  callback = function()
    vim.wo[0][0].foldmethod = "expr"
    vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
    vim.wo[0][0].foldlevel = 99
  end,
})
