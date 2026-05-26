vim.api.nvim_command('set clipboard=unnamedplus')

vim.api.nvim_set_var('netrw_bufsettings', 'noma nomod nu nowrap ro')
vim.g.netrw_liststyle = 3  -- tree view by default
vim.g.netrw_browse_split = 3  -- <CR> on file opens in new tab; dirs still descend in place

vim.api.nvim_create_autocmd("TermOpen", {
  pattern = "*",
  callback = function()
    vim.opt_local.number = true
    vim.opt_local.relativenumber = true
    -- Override Visual selection colour in terminal windows (see NvimTerminalVisual in colors.lua)
    local wh = vim.wo.winhighlight
    vim.wo.winhighlight = (wh ~= "" and wh .. "," or "") .. "Visual:NvimTerminalVisual"
  end,
})

-- Terminal-normal mode (nt) cursor: bright green via OSC 12 escape sequence.
--
-- WHY not guicursor: "nt" is not a valid guicursor mode string (E546). Neovim's
-- cursor shape table has no entry for nt — it reuses SHAPE_IDX_N (normal mode).
--
-- WHY not nvim_set_hl(Cursor/TermCursor): Cursor applies to normal mode only;
-- TermCursor was for the virtual cursor drawn inside a terminal buffer in t-mode,
-- but that was removed in nvim PR #31562. Neither hl group affects nt-mode cursor.
--
-- SOLUTION: OSC 12 / OSC 112 — escape sequences sent to the outer terminal emulator
-- (Windows Terminal) directly via io.write to nvim's stdout. Windows Terminal
-- honours these to set / reset the cursor colour at the terminal level.
--   OSC 12 ; <colour> BEL  — set cursor colour
--   OSC 112 BEL            — reset to terminal default
--
-- WHY defer on enter: when pressing Ctrl-e (t→nt), the shell may redraw its prompt
-- via the pty immediately after the mode change, emitting cursor sequences that
-- override ours. Deferring 80 ms lets that output flush first.
--
-- Cursor colour defined here; Visual selection colour defined in after/plugin/colors.lua
-- as NvimTerminalVisual (adjust both there to restyle terminal mode appearance).
local TERMINAL_CURSOR_COLOR = "#39ff14"  -- bright/neon green

local function cursor_terminal()
  io.write("\027]12;" .. TERMINAL_CURSOR_COLOR .. "\007")
  io.flush()
end
local function cursor_reset()
  io.write("\027]112\007")
  io.flush()
end

vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "*:nt",
  callback = function() vim.defer_fn(cursor_terminal, 80) end,
})
vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "nt:*",
  callback = cursor_reset,
})

-- Re-enter terminal mode when nvim regains focus while a terminal buffer is active
vim.api.nvim_create_autocmd("FocusGained", {
  callback = function()
    if vim.bo.buftype == "terminal" then
      vim.cmd("startinsert")
    end
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
vim.opt.ignorecase = true  -- case insensitive by default
vim.opt.smartcase = true   -- case sensitive if search contains uppercase

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
