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

-- The tmux target for this terminal buffer: the session that is on screen in it
-- *right now*, as a session id ($N).
--
-- What is on screen is a property of the tmux client, not of the session the
-- terminal was opened with, and the two drift apart in two ways:
--
--   C-b $  renames the session, so the name recorded at creation stops
--          resolving — `-t nvt-73820-1` then fails with "can't find pane",
--          which surfaced as "tmux capture-pane failed".
--   C-b s  switches the client to a different session, and the old one lives on
--          detached — so the recorded name still resolves, just to the wrong
--          session, and <C-e> quietly showed a stale pane's scrollback.
--
-- So ask the client. It is found by the pty it runs on, which nothing renames or
-- switches, and it reports the session it is currently displaying. b:tmux_session
-- is only the fallback for when there is no client left to ask (the terminal was
-- closed, or tmux is gone).
local function tmux_target()
  local stored = vim.b.tmux_session
  if not stored then return nil end               -- not a tmux terminal

  local pid = vim.b.terminal_job_pid
  local tty = pid and vim.fn.resolve('/proc/' .. pid .. '/fd/0') or ''
  if tty:match('^/dev/pts/%d+$') then
    local clients = vim.fn.systemlist(
      { 'tmux', 'list-clients', '-F', '#{client_tty} #{session_id}' })
    if vim.v.shell_error == 0 then
      for _, line in ipairs(clients) do
        local ctty, cid = line:match('^(%S+)%s+(%$%d+)$')
        if ctty == tty then return cid end
      end
    end
  end

  if stored:match('^%$%d+$') then return stored end
  local id = vim.fn.system({ 'tmux', 'display-message', '-p', '-t', stored, '#{session_id}' })
    :gsub('%s+$', '')
  if vim.v.shell_error == 0 and id:match('^%$%d+$') then
    vim.b.tmux_session = id
    return id
  end
  return stored                                   -- nothing left to go on
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
    -- a tmux terminal: terminal_job_pid is the tmux client, whose cwd is frozen
    -- at launch — ask tmux for the active pane's live directory instead
    local target = tmux_target()
    if target then
      local p = vim.fn.system(
        { 'tmux', 'display-message', '-p', '-t', target, '#{pane_current_path}' }
      ):gsub('%s+$', '')
      if vim.v.shell_error == 0 and p ~= '' then return p end
    end
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

-- <C-e> in a tmux terminal: dump the pane's scrollback (history + current
-- screen) into a scratch buffer, shown as a large split *above* the terminal —
-- the terminal shrinks to a thin strip at the bottom so you can copy from the
-- scrollback and paste into the live shell without losing sight of either.
--
-- The scrollback buffer is real and modifiable — visual mode, `/` search,
-- macros, `:g`, edits all work. `i` (or <C-e> again *in it*) closes the split;
-- <C-i> is insert mode *in the scrollback*, since `i` is spoken for. Those two
-- are the only keys this buffer takes: `a`, `I`, `A` and `q` used to close it
-- too, which meant append, insert-at-line-start and macro recording were all
-- unreachable in a buffer whose whole point is that it edits like any other.
-- Pressing <C-e> again *from the terminal* while the split is open re-captures
-- and refreshes it in place.
--
-- <C-i> and <Tab> are the same byte to a terminal, so this also rebinds <Tab>
-- (jump-forward in the jumplist) inside this buffer — nothing to jump to in a
-- scratch buffer, so it costs nothing.
--
-- Pre-tmux, <C-e> dropped into terminal-normal mode over a buffer that *was*
-- the scrollback; tmux's alternate screen means the :terminal buffer only ever
-- holds the visible grid, so the history has to be pulled with `capture-pane`.
local scrollback_seq = 0
local TERM_STRIP_HEIGHT = 6

local function capture_scrollback(session)
  local lines = vim.fn.systemlist({
    'tmux', 'capture-pane', '-p', '-J', '-S', '-', '-t', session,
  })
  if vim.v.shell_error ~= 0 then return nil end
  while #lines > 0 and lines[#lines]:match('^%s*$') do lines[#lines] = nil end
  if #lines == 0 then lines = { '' } end
  return lines
end

local function open_tmux_scrollback()
  local session = tmux_target()
  local term_buf = vim.api.nvim_get_current_buf()
  local term_win = vim.api.nvim_get_current_win()
  local to_normal = vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true)

  if not session then
    vim.api.nvim_feedkeys(to_normal, 'n', false)  -- plain terminal-normal mode
    return
  end

  -- already open for this terminal → refresh in place and focus it
  local cur = vim.b[term_buf].nvt_scrollback
  if cur and vim.api.nvim_win_is_valid(cur.win) and vim.api.nvim_buf_is_valid(cur.buf)
     and vim.api.nvim_win_get_buf(cur.win) == cur.buf then
    local lines = capture_scrollback(session)
    if lines then
      vim.api.nvim_buf_set_lines(cur.buf, 0, -1, false, lines)
      vim.bo[cur.buf].modified = false
    end
    vim.api.nvim_feedkeys(to_normal, 'n', false)
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(cur.win) then
        vim.api.nvim_set_current_win(cur.win)
        vim.cmd('normal! G')
      end
    end)
    return
  end

  local lines = capture_scrollback(session)
  if not lines then
    vim.notify('tmux capture-pane failed', vim.log.levels.ERROR)
    return
  end

  scrollback_seq = scrollback_seq + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_buf_set_name, buf, ('tmux-scrollback://%s/%d'):format(session, scrollback_seq))

  local function close_split()
    vim.b[term_buf].nvt_scrollback = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then pcall(vim.api.nvim_win_close, w, true) end
    end
    if vim.api.nvim_win_is_valid(term_win) then
      vim.api.nvim_set_current_win(term_win)
      vim.cmd('startinsert')
    end
  end
  for _, k in ipairs({ 'i', '<C-e>' }) do
    vim.keymap.set('n', k, close_split, { buffer = buf, desc = 'Close scrollback, back to terminal' })
  end
  vim.keymap.set('n', '<C-i>', function() vim.cmd('startinsert') end,
    { buffer = buf, desc = 'Insert mode in the scrollback buffer' })

  vim.api.nvim_feedkeys(to_normal, 'n', false)
  vim.schedule(function()
    if not (vim.api.nvim_win_is_valid(term_win) and vim.api.nvim_buf_is_valid(buf)) then return end
    vim.api.nvim_set_current_win(term_win)
    vim.cmd('aboveleft split')
    local sb_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(sb_win, buf)
    vim.api.nvim_win_set_height(term_win, TERM_STRIP_HEIGHT)
    vim.b[term_buf].nvt_scrollback = { win = sb_win, buf = buf }
    vim.api.nvim_set_current_win(sb_win)
    vim.cmd('normal! G')
  end)
end

-- Open a :terminal in the current window running a fresh tmux session, lcd'd to
-- `dir`. Records the session id in b:tmux_session (see tmux_target).
local function open_tmux_terminal(dir)
  tmux_session_seq = tmux_session_seq + 1
  local session = ('nvt-%d-%d'):format(vim.fn.getpid(), tmux_session_seq)
  vim.cmd('lcd ' .. vim.fn.fnameescape(dir))
  -- Two steps rather than one create-and-attach, purely to learn the id:
  -- detached creation prints it, and attaching by name straight afterwards is
  -- safe because the name is still the one we just gave it.
  local id = vim.fn.system(
    { 'tmux', 'new-session', '-d', '-P', '-F', '#{session_id}', '-s', session, '-c', dir }
  ):gsub('%s+$', '')
  if vim.v.shell_error ~= 0 or not id:match('^%$%d+$') then
    id = nil  -- tmux refused; fall back to creating it from inside the terminal
  end
  vim.cmd('terminal tmux ' .. (id and ('attach-session -t ' .. session)
                                  or  ('new-session -s ' .. session)))
  vim.b.tmux_session = id or session
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

-- terminal-mode tmux control keys. <C-s>/<C-n> forward the tmux prefix
-- (C-b = 0x02) plus a key; <C-h>/<C-l>/<C-q> forward the raw ctrl char, which
-- ~/.tmux.conf catches as root-table (prefix-free) bindings.
local function term_send(byte)
  return function() vim.api.nvim_chan_send(vim.b.terminal_job_id, byte) end
end
vim.keymap.set('t', '<C-s>', term_send('\x02%'), { desc = 'tmux: split pane (side by side)' })
vim.keymap.set('t', '<C-n>', term_send('\x02c'), { desc = 'tmux: new window' })
vim.keymap.set('t', '<C-h>', term_send('\x08'),  { desc = 'tmux: previous window' })
vim.keymap.set('t', '<C-l>', term_send('\x0c'),  { desc = 'tmux: next window' })
vim.keymap.set('t', '<C-q>', term_send('\x11'),  { desc = 'tmux: close pane' })
-- <C-]>/<C-\>: move the current tmux window one index left/right (prefix + </>).
-- Ctrl+[ is not available: it *is* Escape (0x1b), so mapping it here would
-- swallow <Esc> for tmux copy-mode and every program inside the pane.
vim.keymap.set('t', '<C-\\>', term_send('\x02<'), { desc = 'tmux: move window left' })
vim.keymap.set('t', '<C-]>',  term_send('\x02>'), { desc = 'tmux: move window right' })
-- <A-h/j/k/l>: move between tmux panes (prefix + h/j/k/l → select-pane)
vim.keymap.set('t', '<A-h>', term_send('\x02h'), { desc = 'tmux: select pane left' })
vim.keymap.set('t', '<A-j>', term_send('\x02j'), { desc = 'tmux: select pane down' })
vim.keymap.set('t', '<A-k>', term_send('\x02k'), { desc = 'tmux: select pane up' })
vim.keymap.set('t', '<A-l>', term_send('\x02l'), { desc = 'tmux: select pane right' })

-- <C-k>/<C-j>: scroll the program in the pane, by synthesising a mouse wheel
-- event rather than a key. Every terminal here runs tmux with `mouse on`
-- (~/.tmux.conf), so tmux (or whatever full-screen program inside the pane has
-- turned mouse reporting on — less, lazygit, an inner nvim) reads the wheel and
-- scrolls its own scrollback / copy-mode. There is no key that means "scroll"
-- to all of them; the wheel is the one input they all already understand.
--
-- The bytes are an SGR (1006) mouse report — `ESC [ < <button> ; <col> ; <row> M`
-- — with button 64 = wheel up, 65 = wheel down. Coordinates are 1-based and
-- client-wide, which is exactly what wincol()/winline() give (the terminal grid
-- is the window), so the event lands in the pane holding the cursor: the active
-- one. A pane whose program has *not* enabled mouse reporting would see the
-- sequence as typed text, but with tmux always in between that case does not
-- arise here.
--
-- Cost: the shell no longer receives C-j (readline accept-line, same as <CR>)
-- or C-k (kill-to-end-of-line). C-k is the real loss; scrolling without
-- reaching for the mouse was worth more.
--
-- Mapped buffer-locally on TermOpen, i.e. only in this nvim's :terminal
-- buffers. Terminal mode implies a terminal buffer anyway, but keeping the maps
-- off the global table means C-j/C-k are untouched everywhere else, including
-- for anything that puts a non-terminal buffer in a terminal-ish mode.
local function term_wheel(button)
  return function()
    local job = vim.b.terminal_job_id
    if not job then return end
    vim.api.nvim_chan_send(job, ('\27[<%d;%d;%dM'):format(button, vim.fn.wincol(), vim.fn.winline()))
  end
end
vim.api.nvim_create_autocmd('TermOpen', {
  callback = function(ev)
    vim.keymap.set('t', '<C-k>', term_wheel(64), { buffer = ev.buf, desc = 'Scroll pane up (mouse wheel up)' })
    vim.keymap.set('t', '<C-j>', term_wheel(65), { buffer = ev.buf, desc = 'Scroll pane down (mouse wheel down)' })
  end,
})

-- terminal-mode <C-t>: "fork" — open a new Windows Terminal window at this
-- pane's live cwd. It boots the full stack fresh (zsh → nvim → :terminal →
-- tmux → zsh, via the zshrc auto-launch), an independent session. This window
-- is left completely untouched. Same action as normal-mode <C-t>t.
vim.keymap.set('t', '<C-t>', open_term_window, { desc = 'Fork: new WT window at this pane cwd' })

-- <C-o>: forward to terminal — lets shell/fzf/etc. receive it.
vim.keymap.set('t', '<C-o>', function()
  vim.api.nvim_chan_send(vim.b.terminal_job_id, '\x0f')
end, { desc = 'Forward <C-o> to terminal' })

-- <C-e> — leave the terminal. In a tmux terminal it opens the pane's scrollback
-- as a scratch buffer (see open_tmux_scrollback); anywhere else it just drops to
-- terminal-normal mode.
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
vim.keymap.set('t', '<C-e>', open_tmux_scrollback, { desc = 'Terminal scrollback (tmux) / exit terminal mode' })

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
