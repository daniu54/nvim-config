-- tabs.lua — tab management, under the <C-f> chord.
--
-- These used to hang off <C-t>, which was wrong: <C-t> is the terminal chord
-- (<C-t>t / <C-t>T open one), and <C-b> is tmux's prefix inside it, so both
-- are spoken for by the terminal running in the split next to you. <C-f> is
-- free — nothing in this config used it — and the builtin it displaces is
-- page-forward, which is already <PageDown>, J and <C-d> here.
--
-- <Home>/<End> move between tabs. They were <PageUp>/<PageDown> first, which
-- was the wrong key to spend: J/K are non-recursive maps *onto* <PageDown>/
-- <PageUp>, so taking those keys left the aliases pointing at a tab switch
-- and paging with J/K quietly became tab-walking. <Home>/<End> displace
-- start-of-line and end-of-line instead, which are 0/^ and $ here anyway.
--
-- Direction follows the tabline, not vim's numbering-by-recency instincts:
-- <Home> goes left, <End> goes right. gt/gT stay as remap.lua has them
-- (reversed from stock).

local map = function(lhs, rhs, desc)
  vim.keymap.set('n', lhs, rhs, { desc = desc })
end

-- ── walking the tabline ────────────────────────────────────────────────────

map('<Home>', function() vim.cmd('tabprevious') end, 'Previous tab (left in the tabline)')
map('<End>',  function() vim.cmd('tabnext') end,     'Next tab (right in the tabline)')

-- ── <C-f> chord ────────────────────────────────────────────────────────────

map('<C-f>n', function() vim.cmd('tabnew') end,   'New empty tab')
map('<C-f>x', function() vim.cmd('tabclose') end, 'Close this tab')

-- o for "only", as in :only / <C-w>o — close every tab but this one.
map('<C-f>o', function() vim.cmd('tabonly') end, 'Close all tabs but this one')

-- Pull the previous tab's buffer into the new split, closing that tab if it
-- was single-window.
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

-- Fold two tabs into one split: original buffer keeps the focus.
map('<C-f>s', function() split_with_prev_tab('leftabove split', 'j') end,
  'Hsplit: original buf bottom (focused), prev-tab buf top')
map('<C-f>v', function() split_with_prev_tab('rightbelow vsplit', 'h') end,
  'Vsplit: original buf left (focused), prev-tab buf right')

-- The inverse: pull this split back out into its own tab. (Was <C-t>o, which
-- o now needs for "only".)
map('<C-f>m', function() vim.cmd('wincmd T') end, 'Move this split into its own tab (maximize)')

map('<C-f><', function()
  local idx = vim.fn.tabpagenr()
  if idx > 1 then vim.cmd('tabmove ' .. (idx - 2)) end
end, 'Move this tab left')

map('<C-f>>', function()
  local idx = vim.fn.tabpagenr()
  if idx < vim.fn.tabpagenr('$') then vim.cmd('tabmove ' .. idx) end
end, 'Move this tab right')

-- ── <C-f>b: the tab picker ─────────────────────────────────────────────────
--
-- Telescope over the tab list rather than a plugin: a tab has nothing to show
-- but the buffers open in it, so the whole picker is that one line of display
-- text. Required lazily so this file costs nothing if telescope is absent.
local function pick_tab()
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('tabs: telescope is not available', vim.log.levels.WARN)
    return
  end
  local finders = require('telescope.finders')
  local conf    = require('telescope.config').values
  local actions = require('telescope.actions')
  local astate  = require('telescope.actions.state')

  local current_tab = vim.api.nvim_get_current_tabpage()
  local entries     = {}

  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local seen, buf_names = {}, {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local bname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
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

map('<C-f>b', pick_tab, 'Pick a tab (telescope)')
