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
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local tab_utils = require('shared.tab_utils')

-- <CR>: if the selected file is already open in some tab, just focus that
-- tab/window. Otherwise fall through to the default "open in new tab".
local function select_or_focus_tab(prompt_bufnr)
  local entry = action_state.get_selected_entry()
  local path = entry and (entry.path or entry.filename)
  local tab, win
  if path then
    tab, win = tab_utils.find_tab_with_file(path)
  end

  if tab then
    -- Close the picker first: closing after switching tabs would leave the
    -- prompt buffer's tab, triggering telescope's BufLeave-close-prompt
    -- autocmd and clearing the picker state actions.close() depends on.
    actions.close(prompt_bufnr)
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(win)
    return
  end
  actions.select_tab(prompt_bufnr)
end

-- Wrap opts to make <CR> open the selected file in a new tab (or focus its
-- existing tab, if already open).
local function in_tab(opts)
  opts = opts or {}
  opts.attach_mappings = function(_, map)
    map({ 'i', 'n' }, '<CR>', select_or_focus_tab)
    return true
  end
  return opts
end

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

-- Walk up from `dir` toward the filesystem root, stopping at the first
-- directory that contains a project-root marker (.git, go.mod, etc.).
-- Goes at most `max_up` levels; returns the original `dir` if nothing is found.
local project_markers = { '.git', 'go.mod', 'package.json', 'pyproject.toml', 'Cargo.toml' }
local function find_project_root(dir, max_up)
  local d = dir
  for _ = 1, (max_up or 3) do
    for _, marker in ipairs(project_markers) do
      if vim.fn.isdirectory(d .. '/' .. marker) == 1
        or vim.fn.filereadable(d .. '/' .. marker) == 1 then
        return d
      end
    end
    local parent = vim.fn.fnamemodify(d, ':h')
    if parent == d then break end   -- reached filesystem root
    d = parent
  end
  return dir
end

local function search_cwd()
  return find_project_root(ctx_cwd())
end

-- Returns the current visual selection as a single line of text.
-- Saves and restores register z to avoid clobbering the user's registers.
local function get_visual_selection()
  local saved_reg = vim.fn.getreg('z')
  local saved_regtype = vim.fn.getregtype('z')
  vim.cmd('normal! "zy')
  local text = vim.fn.getreg('z')
  vim.fn.setreg('z', saved_reg, saved_regtype)
  -- Telescope default_text is single-line; strip everything after the first newline
  return (text:gsub('\n.*', ''))
end

-- <C-o>: find files from vim's cwd (stable — does NOT shift with current buffer/netrw).
-- Mirrors VSCode ctrl+o (quickOpen → file picker).
-- NOTE: overrides nvim's built-in <C-o> (jumplist back)
vim.keymap.set('n', '<C-o>', function()
  builtin.find_files(in_tab({ cwd = vim.fn.getcwd() }))
end, { desc = 'Telescope: find files (cwd, new tab)' })

-- Visual <C-o>: find files with selection pre-filled
vim.keymap.set('v', '<C-o>', function()
  local text = get_visual_selection()
  builtin.find_files(in_tab({ cwd = vim.fn.getcwd(), default_text = text }))
end, { desc = 'Telescope: find files (cwd, selection, new tab)' })

-- <leader>fg: live grep from vim's cwd (stable)
vim.keymap.set('n', '<leader>fg', function()
  builtin.live_grep(in_tab({ cwd = vim.fn.getcwd() }))
end, { desc = 'Telescope: live grep (cwd, new tab)' })

-- Visual <leader>fg: live grep with selection pre-filled
vim.keymap.set('v', '<leader>fg', function()
  local text = get_visual_selection()
  builtin.live_grep(in_tab({ cwd = vim.fn.getcwd(), default_text = text }))
end, { desc = 'Telescope: live grep (cwd, selection, new tab)' })

-- <leader>O: lcd to context dir (project root walk from netrw curdir / file dir),
-- then find files. The "shift" variant of <C-o> — explicitly moves the active
-- directory before searching.
vim.keymap.set('n', '<leader>O', function()
  local dir = search_cwd()
  vim.cmd('lcd ' .. vim.fn.fnameescape(dir))
  builtin.find_files({ cwd = dir })
end, { desc = 'Telescope: lcd to ctx + find files' })

-- <leader>fG: lcd to context dir, then live grep. Shift variant of <leader>fg.
vim.keymap.set('n', '<leader>fG', function()
  local dir = search_cwd()
  vim.cmd('lcd ' .. vim.fn.fnameescape(dir))
  builtin.live_grep({ cwd = dir })
end, { desc = 'Telescope: lcd to ctx + live grep' })

-- <leader>fo: recent files — mirrors VSCode ctrl+shift+o (openRecent)
vim.keymap.set('n', '<leader>fo', builtin.oldfiles, { desc = 'Telescope: recent files' })

-- <leader>fb: open buffers
vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Telescope: buffers' })

-- Every nvim :terminal runs one tmux session inside it (see ~/.tmux.conf):
--
--   nvim -> nvim :terminal -> tmux (session "nvt-<pid>-<n>") -> zsh
--
-- All sessions share the one per-user tmux server, so `tmux attach -t <name>`
-- from any other Windows Terminal window reconnects to that shell — which is
-- what terminal-mode <C-t> does (open a new WT window attached here, then
-- close this one). Splitting and new "windows" are tmux's job now: terminal
-- mode <C-s> forwards the tmux "split pane" chord and <C-n> "new window",
-- and the C-b prefix passes straight through for everything else.
--
-- Nested nvim (nvim run *inside* the nvim terminal) is no longer special-cased:
-- tmux hides the pane process tree, so the old <C-e>/<C-t>/<C-p> "forward to the
-- inner nvim" walk could not see it anyway. These keys are now always handled
-- by the outer nvim.

local tmux_session_seq = 0

-- Open a :terminal in the current window running a fresh tmux session, lcd'd to
-- `dir`. Records the session name in b:tmux_session for terminal-mode <C-t>.
local function open_tmux_terminal(dir)
  tmux_session_seq = tmux_session_seq + 1
  local session = ('nvt-%d-%d'):format(vim.fn.getpid(), tmux_session_seq)
  vim.cmd('lcd ' .. vim.fn.fnameescape(dir))
  vim.cmd('terminal tmux new-session -s ' .. session)
  vim.b.tmux_session = session
  vim.cmd('startinsert')
end

-- :TmuxTerm — turn the current window into a tmux terminal at the cwd. This is
-- what zshrc's shell auto-launch calls (`nvim +TmuxTerm .`), so the everyday
-- terminal — not just the <C-s> / <C-t>T splits — runs tmux.
vim.api.nvim_create_user_command('TmuxTerm', function()
  open_tmux_terminal(vim.fn.getcwd())
end, { desc = 'Open a tmux terminal in the current window' })

-- <C-t>T: open terminal in a vertical split to the side at context directory
-- works in normal, netrw, and terminal buffers
local function open_term_side()
  local dir = ctx_cwd()
  vim.cmd('vsplit')
  open_tmux_terminal(dir)
end

-- terminal-mode <C-t>: re-open *this* terminal's tmux session in a new Windows
-- Terminal window (detaching this one). Continue there, close this window — the
-- session lives in the shared tmux server, not in either WT window.
local function reattach_in_new_window()
  local session = vim.b.tmux_session
  if not session then
    vim.notify('<C-t>: this terminal is not running a tmux session', vim.log.levels.WARN)
    return
  end
  -- tmux knows the pane's live cwd; ctx_cwd() only sees tmux's start dir
  local dir = vim.fn.system(
    { 'tmux', 'display-message', '-p', '-t', session, '#{pane_current_path}' }
  ):gsub('%s+$', '')
  if vim.v.shell_error ~= 0 or dir == '' then dir = ctx_cwd() end
  local win_dir = vim.fn.system({ 'wslpath', '-w', dir }):gsub('%s+$', '')
  local cmd = { 'wt.exe' }
  if vim.v.shell_error == 0 and win_dir ~= '' then
    vim.list_extend(cmd, { '-d', win_dir })
  end
  vim.list_extend(cmd, { 'wsl.exe', '--', 'tmux', 'new-session', '-A', '-D', '-s', session })
  vim.fn.jobstart(cmd, { detach = true })
end

-- <C-t>T: open terminal in vertical split to the side
vim.keymap.set('n', '<C-t>T', open_term_side, { desc = 'Open terminal in vertical split at context dir' })

-- <C-t>t: open a new *detached* Windows Terminal window at the context directory.
-- The window-manager sibling of <C-t>T (which splits inside this nvim); it is the
-- `tw` zsh alias (`wt.exe -d "$(wslpath -w .)"`) inlined, since a non-interactive
-- shell would not see that alias.
local function open_term_window()
  local dir = ctx_cwd()
  local win_dir = vim.fn.system({ 'wslpath', '-w', dir }):gsub('%s+$', '')
  if vim.v.shell_error ~= 0 or win_dir == '' then
    vim.notify('wslpath failed for: ' .. dir, vim.log.levels.ERROR)
    return
  end
  -- detach: the window must outlive this nvim, and nvim must not wait on it
  vim.fn.jobstart({ 'wt.exe', '-d', win_dir }, { detach = true })
end
vim.keymap.set('n', '<C-t>t', open_term_window, { desc = 'Open new Windows Terminal window at context dir' })

-- <C-t>n: new empty tab
vim.keymap.set('n', '<C-t>n', function() vim.cmd('tabnew') end, { desc = 'New tab' })

-- <C-t>x: close current tab
vim.keymap.set('n', '<C-t>x', function() vim.cmd('tabclose') end, { desc = 'Close current tab' })

-- Pull the previous tab's buffer into the new split, closing that tab if it was single-window.
local function split_with_prev_tab(split_cmd, focus_wincmd)
  local prev_nr = vim.fn.tabpagenr('#')  -- 1-based; 0 means no previous tab
  local prev_buf, close_prev = nil, false

  if prev_nr > 0 then
    local tabs = vim.api.nvim_list_tabpages()
    if prev_nr <= #tabs then
      local prev_tab = tabs[prev_nr]
      local wins = vim.api.nvim_tabpage_list_wins(prev_tab)
      prev_buf   = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(prev_tab))
      close_prev = (#wins == 1)
    end
  end

  vim.cmd(split_cmd)

  if prev_buf then
    vim.api.nvim_win_set_buf(0, prev_buf)
    if close_prev then
      vim.cmd('tabclose ' .. prev_nr)
    end
  else
    vim.cmd('enew')
  end

  vim.cmd('wincmd ' .. focus_wincmd)
end

-- <C-t>s: split horizontally — original buffer bottom (focused), prev-tab buffer top
vim.keymap.set('n', '<C-t>s', function()
  split_with_prev_tab('leftabove split', 'j')
end, { desc = 'Hsplit: original buf bottom (focused), prev-tab buf top' })

-- <C-t>v: split vertically — original buffer left (focused), prev-tab buffer right
vim.keymap.set('n', '<C-t>v', function()
  split_with_prev_tab('rightbelow vsplit', 'h')
end, { desc = 'Vsplit: original buf left (focused), prev-tab buf right' })

-- <C-t>o: move current split into its own new tab (like <C-w>T)
vim.keymap.set('n', '<C-t>o', function()
  vim.cmd('wincmd T')
end, { desc = 'Move current split to new tab (maximize)' })

-- <C-t>b: telescope tab picker
local function pick_tab()
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf    = require('telescope.config').values
  local actions = require('telescope.actions')
  local astate  = require('telescope.actions.state')

  local tabs        = vim.api.nvim_list_tabpages()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local entries     = {}

  for i, tab in ipairs(tabs) do
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    local seen = {}
    local buf_names = {}
    for _, win in ipairs(wins) do
      local buf   = vim.api.nvim_win_get_buf(win)
      local bname = vim.api.nvim_buf_get_name(buf)
      bname = bname == '' and '[No Name]' or vim.fn.fnamemodify(bname, ':~:.')
      if not seen[bname] then
        seen[bname] = true
        table.insert(buf_names, bname)
      end
    end

    local display = i .. ' │ ' .. table.concat(buf_names, ', ')
    if tab == current_tab then display = display .. '  ← here' end
    table.insert(entries, { tab = tab, display = display })
  end

  pickers.new({}, {
    prompt_title = 'Tabs',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        return { value = e, display = e.display, ordinal = e.display }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, _)
      actions.select_default:replace(function(bufnr)
        local sel = astate.get_selected_entry()
        actions.close(bufnr)
        if sel then vim.api.nvim_set_current_tabpage(sel.value.tab) end
      end)
      return true
    end,
  }):find()
end

vim.keymap.set('n', '<C-t>b', pick_tab, { desc = 'Telescope: pick tab' })

-- <C-t><: move current tab one position to the left
vim.keymap.set('n', '<C-t><', function()
  local idx = vim.fn.tabpagenr()
  if idx > 1 then vim.cmd('tabmove ' .. (idx - 2)) end
end, { desc = 'Move tab left' })

-- <C-t>>: move current tab one position to the right
vim.keymap.set('n', '<C-t>>', function()
  local idx = vim.fn.tabpagenr()
  local last = vim.fn.tabpagenr('$')
  if idx < last then vim.cmd('tabmove ' .. idx) end
end, { desc = 'Move tab right' })

-- <C-s>: open terminal in a horizontal split below at context directory
local function open_term_split()
  local dir = ctx_cwd()
  vim.cmd('rightbelow split')
  open_tmux_terminal(dir)
end

vim.keymap.set('n', '<C-s>', open_term_split, { desc = 'Open terminal in hsplit below at context dir' })

-- terminal-mode <C-s> / <C-n>: forward the tmux prefix (C-b = 0x02) plus a key,
-- so tmux splits / new windows without the two-key chord.
vim.keymap.set('t', '<C-s>', function()
  vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x02%')  -- prefix + %  → split pane, side by side
end, { desc = 'tmux: split pane (side by side)' })
vim.keymap.set('t', '<C-n>', function()
  vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x02c')  -- prefix + c  → new window
end, { desc = 'tmux: new window' })

-- terminal-mode <C-t>: re-open this tmux session in a new Windows Terminal window
vim.keymap.set('t', '<C-t>', reattach_in_new_window, { desc = 'tmux: re-open this session in a new WT window' })

-- <C-o>: forward to terminal — lets shell/fzf/etc. receive it.
vim.keymap.set('t', '<C-o>', function()
  vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x0f')
end, { desc = 'Forward <C-o> to terminal' })

-- Exit terminal mode — always handled by the outer nvim (see the tmux note above).
--
-- Key choice history — why so many candidates were rejected:
--   <leader><Esc>  — original binding; space (leader) was intercepted on every keypress while
--                    nvim waited for the chord, causing visible input lag in the terminal.
--   <C-Esc>        — Windows system shortcut (opens Start menu); intercepted at the OS level
--                    before Windows Terminal or nvim ever see the key.
--   <C-;>          — requires kitty keyboard protocol to be sent as a distinct chord; without it
--                    the terminal just receives a bare ';'. Didn't work in practice.
--   <S-Esc>        — same kitty keyboard protocol requirement as <C-;>; same failure mode.
--   <M-Esc>        — Windows system shortcut (cycles open windows in z-order); OS-level, same
--                    problem as <C-Esc>.
--   <C-e>          — chosen: no Windows/Whim conflict, no kitty KP needed. Only cost: loses
--                    bash readline's "move cursor to end of line" (C-e) inside nvim terminal
--                    buffers. Acceptable tradeoff.
vim.keymap.set('t', '<C-e>', function()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'n', false)
end, { desc = 'Exit terminal mode' })

-- <C-p>: yank history picker (overrides nvim default <C-p> = move up / prev completion)
-- Works in normal, insert and terminal mode.
-- Normal/insert: pastes selected text at cursor; re-enters insert if triggered from it.
-- Terminal: pastes the selected text into the shell (tmux/readline), then resumes insert.
vim.keymap.set('t', '<C-p>', function()
  local job = vim.b.terminal_job_id
  require('telescope').extensions.neoclip.default({
    attach_mappings = function(_, map)
      local actions = require('telescope.actions')
      local state   = require('telescope.actions.state')
      local function on_select(bufnr)
        local entry = state.get_selected_entry()
        actions.close(bufnr)
        if entry then vim.api.nvim_chan_send(job, table.concat(entry.contents, '\n')) end
        vim.cmd('startinsert')
      end
      map('i', '<CR>', on_select)
      map('n', '<CR>', on_select)
      return true
    end,
  })
end, { desc = 'Yank history picker → paste into shell' })

vim.keymap.set({ 'n', 'i' }, '<C-p>', function()
  local was_insert = vim.api.nvim_get_mode().mode == 'i'

  local opts = {
    attach_mappings = function(_, map)
      local actions = require('telescope.actions')
      local state   = require('telescope.actions.state')
      local function on_select(bufnr)
        local entry = state.get_selected_entry()
        actions.close(bufnr)
        if not entry then return end

        local regtype = entry.regtype == 'V' and 'l' or 'c'
        vim.api.nvim_put(entry.contents, regtype, true, true)
        if was_insert then
          vim.api.nvim_feedkeys('a', 'n', false)
        end
      end
      map('i', '<CR>', on_select)
      map('n', '<CR>', on_select)
      return true
    end
  }

  require('telescope').extensions.neoclip.default(opts)
end, { desc = 'Yank history picker' })
