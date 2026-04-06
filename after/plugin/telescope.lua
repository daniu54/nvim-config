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

-- Returns true if the terminal buffer's shell has a child process running nvim.
-- Used to pass <C-t> through to an inner nvim instead of intercepting it.
local function terminal_child_is_nvim()
  local pid = vim.b.terminal_job_pid
  if not pid then return false end
  local children = vim.fn.system('pgrep -P ' .. pid)
  for child_pid in children:gmatch('%d+') do
    local cmdline = vim.fn.system('cat /proc/' .. child_pid .. '/cmdline 2>/dev/null')
    if cmdline:match('nvim') then return true end
  end
  return false
end

vim.keymap.set('n', '<C-t>', open_term_vsplit, { desc = 'Open terminal in vsplit at context dir' })
vim.keymap.set('t', '<C-t>', function()
  if terminal_child_is_nvim() then
    -- pass raw C-t byte to the terminal so inner nvim receives it
    vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x14')
  else
    -- exit terminal mode, then open the split
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'n', false)
    vim.schedule(open_term_vsplit)
  end
end, { desc = 'Open terminal in vsplit, or pass C-t through to inner nvim' })
