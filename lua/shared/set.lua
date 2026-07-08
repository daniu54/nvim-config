vim.api.nvim_command('set clipboard=unnamedplus')

vim.api.nvim_set_var('netrw_bufsettings', 'noma nomod nu nowrap ro')
vim.g.netrw_liststyle = 3  -- tree view by default
vim.g.netrw_browse_split = 3  -- <CR> on file opens in new tab; dirs still descend in place

vim.api.nvim_create_autocmd("TermOpen", {
  pattern = "*",
  callback = function()
    vim.opt_local.number = true
    vim.opt_local.relativenumber = true
    -- Seed t-mode highlight; ModeChanged will swap it when entering nt (see below)
    vim.wo.winhighlight = "Visual:NvimTerminalTVisual"
  end,
})

-- Terminal mode cursors via OSC 12 / OSC 112 escape sequences sent to Windows Terminal.
--
-- WHY not guicursor: "nt" is not a valid guicursor mode string (E546). Neovim has
-- no cursor table entry for nt — it reuses SHAPE_IDX_N (normal mode).
-- WHY not nvim_set_hl(Cursor/TermCursor): TermCursor was removed in nvim PR #31562.
--
-- OSC 12 ; <colour> BEL  — set cursor colour
-- OSC 112 BEL            — reset to terminal default
--
-- WHY defer on *:nt: when pressing Ctrl-e (t→nt) the shell may redraw its prompt
-- immediately after the mode change, emitting cursor sequences that override ours.
-- Deferring 80 ms lets that output flush first.
--
-- INNER vs OUTER nvim: $NVIM is set by nvim for all child processes. If we see it,
-- we are a nested nvim (launched from inside a terminal buffer). In that case every
-- mode should be green — the orange-vs-green distinction only makes sense for the
-- outermost nvim where orange = "you are in the editor navigating a terminal" and
-- green = "you are now in the shell / deeper in the stack".
--
-- Selection colours (NvimTerminalNVisual / NvimTerminalTVisual) live in colors.lua.

local IS_INNER = vim.env.NVIM ~= nil  -- true when launched from inside another nvim

local CURSOR_NT = IS_INNER and "#39ff14" or "#ff8800"  -- inner: green; outer: orange
local CURSOR_T  = "#39ff14"                             -- always green

local function cursor_nt()    io.write("\027]12;" .. CURSOR_NT .. "\007"); io.flush() end
local function cursor_t()     io.write("\027]12;" .. CURSOR_T  .. "\007"); io.flush() end
local function cursor_reset()
  if IS_INNER then
    cursor_t()  -- inner nvim: "reset" means back to green, not terminal default
  else
    io.write("\027]112\007"); io.flush()
  end
end

-- Inner nvim: set green cursor after full init.
-- WHY VimEnter + defer: nvim switches to the alternate screen buffer (\033[?1049h)
-- during startup, and Windows Terminal resets cursor colour on that switch.
-- An early io.write gets wiped out; VimEnter fires after the switch is done.
if IS_INNER then
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function() vim.defer_fn(cursor_t, 50) end,
  })
end

-- nt mode: cursor + selection colour (orange for outer, green for inner)
vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "*:nt",
  callback = function()
    vim.defer_fn(cursor_nt, 80)
    if vim.bo.buftype == "terminal" then
      vim.wo.winhighlight = IS_INNER
        and "Visual:NvimTerminalTVisual"
        or  "Visual:NvimTerminalNVisual"
    end
  end,
})

-- t mode: green cursor + green selection (deferred like nt to survive prompt redraws)
vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "*:t",
  callback = function()
    if vim.bo.buftype == "terminal" then
      vim.defer_fn(cursor_t, 50)
      vim.wo.winhighlight = "Visual:NvimTerminalTVisual"
    end
  end,
})

-- Reset cursor when leaving both terminal modes (not when switching between them)
vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = { "nt:*", "t:*" },
  callback = function()
    local new = vim.v.event.new_mode
    if new ~= "nt" and new ~= "t" then cursor_reset() end
  end,
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

-- Per-directory config opt-in: if a project root contains a `.nvim.lua` (or
-- `.exrc`/`.nvimrc`), nvim offers to source it on startup. Nvim's trust
-- database (`:h :trust`) prompts once per file before running it, so an
-- untrusted/unknown project's `.nvim.lua` never executes silently.
-- Used to opt a specific project into AI completion (see after/plugin/minuet.lua)
-- and/or LSP autostart, without turning either on globally.
vim.opt.exrc = true

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
