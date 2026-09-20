-- csvview.nvim: auto-enable column alignment + the sticky header for csv/tsv
-- files, plus the two things markdown tables have
-- (after/plugin/markdown_table.lua) and a csv otherwise does not: the label
-- naming the column of the cell under the cursor, and the arrow keys walking
-- the fields one cell at a time.
--
-- **There was a hover float here before** — the column name in a popup, raised
-- on CursorHold — and it is gone. It sat on top of the rows under the cursor,
-- it arrived on the updatetime timer rather than when the cursor moved, and it
-- had to be closed again on every move, which made reading a wide file worse
-- rather than better. The inline label is the same answer drawn in the cell,
-- with no window to get in the way: see lua/shared/table_cell_hint.lua, which
-- is shared with the markdown side so both filetypes look and toggle alike.
local hint = require('shared.table_cell_hint')

local api = vim.api
local augroup = api.nvim_create_augroup('CsvCellHint', { clear = true })

-- The plugin is lazy-loaded on ft=csv/tsv (lua/shared/lazy.lua), so everything
-- here reaches for it from inside a callback and never at startup.
local function csv_view(bufnr)
  local ok, enabled = pcall(require('csvview').is_enabled, bufnr)
  if not ok or not enabled then return nil end
  return require('csvview.view').get(bufnr)
end

local function field_text(bufnr, range)
  if not range then return nil end
  local lines = api.nvim_buf_get_text(
    bufnr, range.start_row - 1, range.start_col, range.end_row - 1, range.end_col, {})
  return table.concat(lines, ' ')
end

local function row_fields(view, row_idx)
  local ok, fields = pcall(view.metrics.get_logical_row_fields, view.metrics, { row_idx = row_idx })
  if not ok then return {} end
  return fields
end

-- ── The current cell's column header, as virtual text ───────────────────────

local function update_hint(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  hint.clear(bufnr)

  local view = csv_view(bufnr)
  if not view or not view.header_lnum then return end

  local ok, cursor = pcall(require('csvview.util').get_cursor, bufnr)
  if not ok or cursor.kind ~= 'field' then return end

  local row, col = cursor.pos[1], cursor.pos[2]
  if not col then return end
  -- On the header row itself the label would only repeat the cell the cursor
  -- is already sitting in.
  if row == view.metrics:get_logical_row_idx(view.header_lnum) then return end

  -- A field that spans physical lines (a quoted newline) has no single range
  -- to hang the pair on, so it goes without.
  local range = row_fields(view, row)[col]
  if not range or range.start_row ~= range.end_row then return end

  local header = field_text(bufnr, row_fields(view, view.metrics:get_logical_row_idx(view.header_lnum))[col])
  if not header or header == '' then return end

  hint.show(bufnr, range.start_row - 1, range.start_col, range.end_col, header)
end

hint.register(update_hint)

-- ── Cell-wise arrow navigation ──────────────────────────────────────────────
--
-- Same contract as the markdown side: <Right> from the last field of a row
-- lands on the first field of the next, and from the last field of the file on
-- the very first; <Down> from the bottom row lands on the top of the column to
-- the right, and from the bottom of the last column on the top of the first.
--
-- csvview's own `jump.field` already wraps *horizontally* (that is its
-- `col_wrap`), but it stops dead at both ends of the file and has no vertical
-- wrap at all, so the destination is worked out here and jumped to absolutely.
local function move_field(drow, dcol)
  local bufnr = api.nvim_get_current_buf()
  local view = csv_view(bufnr)
  if not view then return false end

  local ok, cursor = pcall(require('csvview.util').get_cursor, bufnr)
  if not ok or cursor.kind ~= 'field' then return false end

  local row, col = cursor.pos[1], cursor.pos[2] or 1
  local rows = view.metrics:row_count_logical()
  if rows < 1 then return false end
  local function ncols(r) return math.max(#row_fields(view, r), 1) end

  if dcol ~= 0 then
    col = col + dcol
    if col > ncols(row) then
      row, col = row + 1, 1
      if row > rows then row = 1 end
    elseif col < 1 then
      row = row - 1
      if row < 1 then row = rows end
      col = ncols(row)
    end
  else
    row = row + drow
    if row > rows then
      row, col = 1, col + 1
      if col > ncols(1) then col = 1 end
    elseif row < 1 then
      row, col = rows, col - 1
      if col < 1 then col = ncols(rows) end
    end
    -- A ragged row may be shorter than the column we came from.
    col = math.min(col, ncols(row))
  end

  return pcall(require('csvview.jump').field, bufnr,
    { pos = { row, col }, mode = 'absolute', anchor = 'start' })
end

-- nvim-cmp owns <Up>/<Down> in insert mode (its preset.insert maps them to the
-- menu), and a buffer-local map shadows a global one — so they are handed back
-- whenever the menu is open, exactly as markdown_table.lua does for <Tab>.
local function cmp_handled(action)
  local ok, cmp = pcall(require, 'cmp')
  if not ok or not cmp.visible() then return false end
  if action == 'next' then cmp.select_next_item() else cmp.select_prev_item() end
  return true
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'n', false)
end

local arrow_maps = {
  { '<Right>', function() if not move_field(0, 1) then feed('<Right>') end end,
    'CSV: field to the right, wrapping to the next row' },
  { '<Left>', function() if not move_field(0, -1) then feed('<Left>') end end,
    'CSV: field to the left, wrapping to the previous row' },
  { '<Down>', function()
    if cmp_handled('next') then return end
    if not move_field(1, 0) then feed('<Down>') end
  end, 'CSV: field below, wrapping to the top of the next column' },
  { '<Up>', function()
    if cmp_handled('prev') then return end
    if not move_field(-1, 0) then feed('<Up>') end
  end, 'CSV: field above, wrapping to the bottom of the previous column' },
}

api.nvim_create_autocmd('FileType', {
  group = augroup,
  pattern = { 'csv', 'tsv' },
  callback = function(args)
    local bufnr = args.buf
    -- FileType can fire more than once for the same buffer (lazy.nvim loading
    -- the plugin on the first csv/tsv file re-triggers detection), so the
    -- per-buffer autocmds and maps are registered once.
    if vim.b[bufnr].csvview_cell_hint_setup then return end
    vim.b[bufnr].csvview_cell_hint_setup = true

    if not require('csvview').is_enabled(bufnr) then
      require('csvview').enable(bufnr)
    end

    for _, map in ipairs(arrow_maps) do
      vim.keymap.set({ 'n', 'i' }, map[1], map[2],
        { buffer = bufnr, desc = map[3], silent = true })
    end

    api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'InsertLeave' }, {
      group = augroup,
      buffer = bufnr,
      callback = function() update_hint(bufnr) end,
    })

    api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
      group = augroup,
      buffer = bufnr,
      callback = function() hint.clear(bufnr) end,
    })
  end,
})
