local ok, telescope = pcall(require, 'telescope')
if not ok then return end

telescope.setup({
  defaults = {
    mappings = {
      i = {
        -- Tab: mark item and move DOWN (toward better matches), not up
        ['<Tab>'] = require('telescope.actions').toggle_selection + require('telescope.actions').move_selection_better,
        -- C-q: send only marked items to quickfix (default sends all)
        ['<C-q>'] = require('telescope.actions').send_selected_to_qflist + require('telescope.actions').open_qflist,
      },
      n = {
        ['<Tab>'] = require('telescope.actions').toggle_selection + require('telescope.actions').move_selection_better,
        ['<C-q>'] = require('telescope.actions').send_selected_to_qflist + require('telescope.actions').open_qflist,
      },
    },
    -- Full screen: fill the entire editor window
    layout_strategy = 'flex',
    layout_config = {
      width = 0.99,
      height = 0.99,
      flex = {
        flip_columns = 160,
      },
      horizontal = {
        preview_width = 0.55,
      },
      vertical = {
        preview_height = 0.55,
      },
    },
    -- Show filename first, then the directory path — keeps myfile.md:52:31 visible
    path_display = { 'filename_first' },
    -- Show the file path as the preview pane title
    dynamic_preview_title = true,
  },
})

-- Wrap long lines in the preview pane (preview.wrap in setup() doesn't work;
-- must be applied after the previewer buffer loads)
vim.api.nvim_create_autocmd('User', {
  pattern = 'TelescopePreviewerLoaded',
  callback = function()
    vim.opt_local.wrap = true
  end,
})

local builtin = require('telescope.builtin')

-- Resolve the "context" directory for the current buffer:
--   netrw  → directory being browsed
--   terminal → shell's actual cwd via /proc/<pid>/cwd
--   file   → directory of the current file (fallback)
local function ctx_cwd()
  if vim.bo.filetype == 'netrw' then
    return vim.b.netrw_curdir
  end
  if vim.bo.buftype == 'terminal' then
    local pid = vim.b.terminal_job_pid
    if pid then
      local cwd = vim.fn.resolve('/proc/' .. pid .. '/cwd')
      if cwd and cwd ~= '' then return cwd end
    end
  end
  return vim.fn.expand('%:p:h')
end

-- <C-o>: find files — mirrors VSCode ctrl+o (quickOpen → file picker)
-- NOTE: overrides nvim's built-in <C-o> (jumplist back)
vim.keymap.set('n', '<C-o>', function()
  builtin.find_files({ cwd = ctx_cwd() })
end, { desc = 'Telescope: find files' })

-- <leader>fg: live grep
vim.keymap.set('n', '<leader>fg', function()
  builtin.live_grep({ cwd = ctx_cwd() })
end, { desc = 'Telescope: live grep' })

-- <leader>fo: recent files — mirrors VSCode ctrl+shift+o (openRecent)
vim.keymap.set('n', '<leader>fo', builtin.oldfiles, { desc = 'Telescope: recent files' })

-- <leader>fb: open buffers
vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Telescope: buffers' })

-- <C-t>: open terminal in a vertical split at context directory
-- works in normal, netrw, and terminal buffers
local function open_term_vsplit()
  local dir = ctx_cwd()
  vim.cmd('rightbelow vsplit')
  vim.cmd('lcd ' .. vim.fn.fnameescape(dir))
  vim.cmd('terminal')
  vim.cmd('startinsert')
end

-- Find the PID of an nvim process that is a direct child of the given shell pid.
local function find_inner_nvim_pid(shell_pid)
  local children = vim.fn.system('pgrep -P ' .. shell_pid)
  for child_pid in children:gmatch('%d+') do
    local cmdline = vim.fn.system('cat /proc/' .. child_pid .. '/cmdline 2>/dev/null')
    if cmdline:match('nvim') then return tonumber(child_pid) end
  end
  return nil
end

-- Find the nvim server socket for a given nvim PID by reading $NVIM from one
-- of its child processes (which nvim sets for every process it spawns).
local function find_nvim_socket(nvim_pid)
  local children = vim.fn.system('pgrep -P ' .. nvim_pid)
  for gc_pid in children:gmatch('%d+') do
    local environ = vim.fn.system('cat /proc/' .. gc_pid .. '/environ 2>/dev/null')
    local socket = environ:match('NVIM=([^%z]+)') or environ:match('NVIM_LISTEN_ADDRESS=([^%z]+)')
    if socket and socket ~= '' then return socket end
  end
  return nil
end

-- Returns true if the terminal buffer's shell has a child process running nvim.
-- Used to pass <C-t> through to an inner nvim instead of intercepting it.
local function terminal_child_is_nvim()
  local pid = vim.b.terminal_job_pid
  if not pid then return false end
  return find_inner_nvim_pid(pid) ~= nil
end

-- Returns true if inner nvim's currently focused window is a terminal buffer.
-- Used to decide whether to pass <M-e> through to inner nvim.
local function inner_nvim_terminal_is_active()
  local pid = vim.b.terminal_job_pid
  if not pid then return false end
  local nvim_pid = find_inner_nvim_pid(pid)
  if not nvim_pid then return false end
  local socket = find_nvim_socket(nvim_pid)
  if not socket then return false end
  local result = vim.fn.system(
    'nvim --server ' .. vim.fn.shellescape(socket) ..
    " --remote-expr \"getbufvar(winbufnr(winnr()), '&buftype')\" 2>/dev/null"
  )
  return result:gsub('%s+', '') == 'terminal'
end

vim.keymap.set('n', '<C-t>', open_term_vsplit, { desc = 'Open terminal in vsplit at context dir' })
vim.keymap.set('t', '<C-t>', function()
  -- always pass C-t through to the shell (or inner nvim if running)
  vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x14')
end, { desc = 'Pass C-t through to shell/inner nvim' })

-- <M-e>: exit terminal mode — but if inner nvim's active window is a
-- terminal buffer, send <C-\><C-n> through so inner nvim exits its terminal mode too.
-- Alt+letter works without kitty keyboard protocol (sends ESC+e, always distinguishable).
vim.keymap.set('t', '<M-e>', function()
  if inner_nvim_terminal_is_active() then
    -- <C-\><C-n> is nvim's built-in terminal escape (0x1c 0x0e)
    vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x1c\x0e')
  else
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'n', false)
  end
end, { desc = 'Exit terminal mode, or pass M-e through to inner nvim terminal' })
