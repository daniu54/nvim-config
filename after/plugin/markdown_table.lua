-- markdown_table.lua — Obsidian-style markdown table editing.
--
-- Ports the three things the Obsidian tables plugin does, so the same muscle
-- memory works here (like markdown_edit.lua does for the surround keys):
--
--   * type `| name | age |` and press <CR> (or <Tab>) — the `| --- | --- |`
--     delimiter row is written for you and the line becomes a real table
--   * <Tab> moves to the cell on the right, and *creates* a column when
--     there is none to the right
--   * <CR> moves to the next row, creating one — pipes already in place —
--     when there is none. On an empty last row it drops out of the table
--     instead, so <CR> is also the way out.
--
-- Everything reflows as you type: any of these keys, and InsertLeave, rewrites
-- the whole table with aligned columns.
--
-- **This is deliberately not built on treesitter, and not on table-nvim** (the
-- one plugin that does the same job — SCJangra/table-nvim). Both are ruled out
-- by the same thing: the markdown grammar has no production for a row of blank
-- cells, so a table whose last row is empty parses as an ERROR node and no
-- table can be found in it at all. Verified against both the parser pinned in
-- lazy-lock.json and current tree-sitter-markdown. Since an empty row is
-- exactly what "<CR> makes the next row" has to produce, anything reading the
-- tree would break on its own output from the second row onwards. Parsing the
-- lines as text has no such hole — and it is why a half-built table (a lone
-- `| header |` line) is editable here too, which treesitter also cannot see.
--
-- The cost is that markdown *highlighting* still goes flat over a table with
-- an empty row, since that is the same parser at work. It comes back as soon
-- as the row has content.
--
-- <Tab>, <S-Tab> and <CR> belong to nvim-cmp (after/plugin/cmp.lua) and a
-- buffer-local map shadows a global one, so each handler hands the key back to
-- cmp first whenever the completion menu is open, exactly as cmp.lua maps it.

local api = vim.api
local strwidth = vim.fn.strwidth

-- Minimum rendered column width. 3 is what a `---` delimiter cell wants, and
-- what prettier and every markdown table in this repo's own docs use.
local MIN_WIDTH = 3

local function get_line(lnum)
  return api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
end

local function is_row_line(line)
  return line ~= nil and line:match('^%s*|') ~= nil
end

-- Split a row line into trimmed cell texts. A `\|` is literal text, not a
-- separator.
local function split_cells(line)
  local body = vim.trim(line)
  local cells, cur, i = {}, {}, 1
  if body:sub(1, 1) == '|' then i = 2 end
  while i <= #body do
    local ch = body:sub(i, i)
    if ch == '\\' and body:sub(i + 1, i + 1) == '|' then
      cur[#cur + 1] = '\\|'
      i = i + 2
    elseif ch == '|' then
      cells[#cells + 1] = vim.trim(table.concat(cur))
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = ch
      i = i + 1
    end
  end
  -- A closing `|` ends the last cell; text after it is a cell of its own.
  local rest = vim.trim(table.concat(cur))
  if rest ~= '' or #cells == 0 then cells[#cells + 1] = rest end
  return cells
end

local function alignment_of(cell)
  if cell:match('^:%-+:$') then return 'center' end
  if cell:match('^:%-+$') then return 'left' end
  if cell:match('^%-+:$') then return 'right' end
  if cell:match('^%-+$') then return 'none' end
  return nil
end

local function is_delimiter_row(cells)
  for _, cell in ipairs(cells) do
    if not alignment_of(cell) then return false end
  end
  return #cells > 0
end

-- Fences are counted from the top of the buffer rather than asked of
-- treesitter, for the reason in the header comment: in a buffer this file
-- edits the tree is regularly an ERROR node, and a code fence is the one place
-- a `|` line must be left alone as text.
local function in_code_fence(lnum)
  local fence
  for _, line in ipairs(api.nvim_buf_get_lines(0, 0, lnum - 1, false)) do
    local marker = line:match('^%s*(```+)') or line:match('^%s*(~~~+)')
    if marker then
      if not fence then
        fence = marker:sub(1, 1)
      elseif marker:sub(1, 1) == fence then
        fence = nil
      end
    end
  end
  return fence ~= nil
end

-- Which cell a byte column falls in: one per unescaped `|` to its left.
local function cell_index(line, col, count)
  local upto, n, i = line:sub(1, col), 0, 1
  while true do
    local at = upto:find('|', i, true)
    if not at then break end
    if upto:sub(at - 1, at - 1) ~= '\\' then n = n + 1 end
    i = at + 1
  end
  return math.min(math.max(n, 1), count)
end

-- The table around the cursor: the run of consecutive lines starting with `|`
-- that the cursor line is part of. nil when the cursor is not on such a line.
-- A single header line with no delimiter row under it counts — that is the
-- half-typed table <CR> and <Tab> are meant to finish.
local function parse()
  local cursor = api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2]
  local line = get_line(lnum)
  if not is_row_line(line) or in_code_fence(lnum) then return nil end

  local first, last, total = lnum, lnum, api.nvim_buf_line_count(0)
  while first > 1 and is_row_line(get_line(first - 1)) do first = first - 1 end
  while last < total and is_row_line(get_line(last + 1)) do last = last + 1 end

  local rows, delim, aligns, ncols = {}, nil, {}, 0
  for l = first, last do
    local cells = split_cells(get_line(l))
    local index = l - first + 1
    if not delim and index > 1 and is_delimiter_row(cells) then
      delim = index
      for c, cell in ipairs(cells) do aligns[c] = alignment_of(cell) end
    end
    rows[index] = cells
    ncols = math.max(ncols, #cells)
  end
  -- A ragged table is padded out, so every later step can assume a rectangle.
  for _, row in ipairs(rows) do
    for c = 1, ncols do row[c] = row[c] or '' end
  end

  local row = lnum - first + 1
  return {
    rows = rows,
    ncols = ncols,
    delim = delim,
    aligns = aligns,
    indent = get_line(first):match('^%s*'),
    first = first,
    last = last,
    row = row,
    col = cell_index(line, col, ncols),
  }
end

local function column_widths(t)
  local w = {}
  for c = 1, t.ncols do w[c] = MIN_WIDTH end
  for i, row in ipairs(t.rows) do
    if i ~= t.delim then
      for c, cell in ipairs(row) do w[c] = math.max(w[c], strwidth(cell)) end
    end
  end
  return w
end

local function pad(text, width, align)
  local space = width - strwidth(text)
  if space <= 0 then return text end
  if align == 'right' then return string.rep(' ', space) .. text end
  if align == 'center' then
    local left = math.floor(space / 2)
    return string.rep(' ', left) .. text .. string.rep(' ', space - left)
  end
  return text .. string.rep(' ', space)
end

local function render_row(t, index, w)
  local cells = {}
  for c = 1, t.ncols do
    if index == t.delim then
      local align, n = t.aligns[c], w[c]
      if align == 'center' then
        cells[c] = ':' .. string.rep('-', n - 2) .. ':'
      elseif align == 'left' then
        cells[c] = ':' .. string.rep('-', n - 1)
      elseif align == 'right' then
        cells[c] = string.rep('-', n - 1) .. ':'
      else
        cells[c] = string.rep('-', n)
      end
    else
      cells[c] = pad(t.rows[index][c], w[c], t.aligns[c])
    end
  end
  return t.indent .. '| ' .. table.concat(cells, ' | ') .. ' |'
end

-- Write the model back over the lines it came from, reflowed.
local function flush(t)
  t.w = column_widths(t)
  local lines = {}
  for i = 1, #t.rows do lines[i] = render_row(t, i, t.w) end
  api.nvim_buf_set_lines(0, t.first - 1, t.last, true, lines)
  t.last = t.first + #t.rows - 1
end

-- Put the cursor on the first character of a cell. Only valid after flush(),
-- which is what fixes the column widths this walks over.
local function goto_cell(t, row, col)
  local x = #t.indent + 2
  for c = 1, col - 1 do x = x + t.w[c] + 3 end
  api.nvim_win_set_cursor(0, { t.first + row - 1, x })
end

-- `| name | age |` on its own is not a table until the `| --- | --- |` row
-- below it exists. Obsidian writes that row for you; so does this.
local function ensure_delimiter(t)
  if t.delim then return end
  local delim = {}
  for c = 1, t.ncols do delim[c] = '---' end
  table.insert(t.rows, 2, delim)
  t.delim = 2
  if t.row >= 2 then t.row = t.row + 1 end
end

local function blank_row(t)
  local row = {}
  for c = 1, t.ncols do row[c] = '' end
  return row
end

local function row_is_empty(row)
  for _, cell in ipairs(row) do
    if cell ~= '' then return false end
  end
  return true
end

local function insert_column(t, at)
  for _, row in ipairs(t.rows) do table.insert(row, at, '') end
  table.insert(t.aligns, at, nil)
  t.ncols = t.ncols + 1
end

-- <Tab>: the cell to the right, or a new column when there is nothing to the
-- right.
local function next_cell()
  local t = parse()
  if not t then return false end
  ensure_delimiter(t)

  local col = t.col
  if col >= t.ncols then insert_column(t, col + 1) end

  flush(t)
  goto_cell(t, t.row, col + 1)
  return true
end

-- <S-Tab>: the cell to the left, wrapping to the end of the row above.
local function prev_cell()
  local t = parse()
  if not t then return false end
  ensure_delimiter(t)

  local row, col = t.row, t.col
  if col > 1 then
    col = col - 1
  elseif row > 1 then
    row = row == t.delim + 1 and row - 2 or row - 1 -- step over the `---` row
    col = t.ncols
  end

  flush(t)
  goto_cell(t, math.max(row, 1), col)
  return true
end

-- <CR>: the next row, created when there is none. On an empty last row it
-- leaves the table instead, so there is a way out that is not <Esc>.
local function next_row()
  local t = parse()
  if not t then return false end
  ensure_delimiter(t)

  if t.row == #t.rows and t.row > t.delim and row_is_empty(t.rows[t.row]) then
    table.remove(t.rows, t.row)
    flush(t)
    api.nvim_buf_set_lines(0, t.last, t.last, true, { '' })
    api.nvim_win_set_cursor(0, { t.last + 1, 0 })
    return true
  end

  local target = t.row + 1
  if target == t.delim then target = t.delim + 1 end
  if target > #t.rows then table.insert(t.rows, target, blank_row(t)) end

  flush(t)
  goto_cell(t, target, 1)
  return true
end

-- Reflow the table under the cursor, keeping the cursor in its cell.
local function reformat()
  local t = parse()
  if not t then return false end
  flush(t)
  goto_cell(t, t.row, t.col)
  return true
end

-- nvim-cmp owns these three keys globally and a buffer-local map shadows it,
-- so the menu case is reproduced here exactly as after/plugin/cmp.lua has it —
-- including that <CR> confirms only an entry that was explicitly selected.
local function cmp_handled(action)
  local ok, cmp = pcall(require, 'cmp')
  if not ok or not cmp.visible() then return false end
  if action == 'next' then
    cmp.select_next_item()
  elseif action == 'prev' then
    cmp.select_prev_item()
  else
    if not cmp.get_selected_entry() then return false end
    cmp.confirm()
  end
  return true
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'n', false)
end

-- <A-j>/<A-k> and <A-S-j>/<A-S-k> belong to multicursor everywhere else in
-- this config (after/plugin/multicursor.lua): add / skip a cursor below or
-- above. Inside a table they insert and move rows instead, and outside one
-- they are handed straight back -- the same "give the key back when this file
-- has nothing to do with it" arrangement the <Tab>/<CR> handlers have with
-- nvim-cmp, so a markdown buffer is not the one place with no multiple
-- cursors.
--
-- Handing back means *calling* multicursor, not feeding <A-j> again:
-- feedkeys without remapping would find no mapping at all (nothing else binds
-- these keys), and with remapping it would land straight back in this map.
local function multicursor(fn, dir)
  return function()
    local ok, mc = pcall(require, 'multicursor-nvim')
    if ok then mc[fn](dir) end
  end
end

-- An operation on the table under the cursor: mutate the model, then say which
-- cell to land on. Outside a table it runs `fallback`, or does nothing when
-- there is none.
local function op(fn, fallback)
  return function()
    local t = parse()
    if not t then
      if fallback then fallback() end
      return
    end
    ensure_delimiter(t)
    local row, col = fn(t)
    flush(t)
    goto_cell(t, math.min(row or t.row, #t.rows), math.min(col or t.col, t.ncols))
  end
end

local function new_table()
  local lnum = api.nvim_win_get_cursor(0)[1]
  local indent = (get_line(lnum) or ''):match('^%s*')
  api.nvim_buf_set_lines(0, lnum - 1, lnum, true, {
    indent .. '|     |     |',
    indent .. '| --- | --- |',
    indent .. '|     |     |',
  })
  api.nvim_win_set_cursor(0, { lnum, #indent + 2 })
end

local alignments = { 'none', 'left', 'center', 'right' }

local table_filetypes = { markdown = true, mdx = true }

local table_maps = {
  { { 'i', 'n' }, '<Tab>', function()
    if cmp_handled('next') then return end
    if not next_cell() then feed('<Tab>') end
  end, 'Table: next cell (creates a column past the last one)' },

  { { 'i', 'n' }, '<S-Tab>', function()
    if cmp_handled('prev') then return end
    if not prev_cell() then feed('<S-Tab>') end
  end, 'Table: previous cell' },

  { { 'i' }, '<CR>', function()
    if cmp_handled('confirm') then return end
    if not next_row() then feed('<CR>') end
  end, 'Table: next row (creates one past the last; empty row leaves the table)' },

  { { 'n' }, '<A-l>', op(function(t)
    insert_column(t, t.col + 1)
    return t.row, t.col + 1
  end), 'Table: insert column right' },

  { { 'n' }, '<A-h>', op(function(t)
    insert_column(t, t.col)
    return t.row, t.col
  end), 'Table: insert column left' },

  { { 'n' }, '<A-j>', op(function(t)
    local at = math.max(t.row + 1, t.delim + 1)
    table.insert(t.rows, at, blank_row(t))
    return at, 1
  end, multicursor('lineAddCursor', 1)), 'Table: insert row below (outside a table: add a cursor below)' },

  { { 'n' }, '<A-k>', op(function(t)
    local at = math.max(t.row, t.delim + 1)
    table.insert(t.rows, at, blank_row(t))
    return at, 1
  end, multicursor('lineAddCursor', -1)), 'Table: insert row above (outside a table: add a cursor above)' },

  { { 'n' }, '<A-d>', op(function(t)
    if t.ncols < 2 then return t.row, t.col end
    for _, row in ipairs(t.rows) do table.remove(row, t.col) end
    table.remove(t.aligns, t.col)
    t.ncols = t.ncols - 1
    return t.row, math.min(t.col, t.ncols)
  end), 'Table: delete column' },

  { { 'n' }, '<A-S-l>', op(function(t)
    if t.col >= t.ncols then return t.row, t.col end
    for _, row in ipairs(t.rows) do row[t.col], row[t.col + 1] = row[t.col + 1], row[t.col] end
    t.aligns[t.col], t.aligns[t.col + 1] = t.aligns[t.col + 1], t.aligns[t.col]
    return t.row, t.col + 1
  end), 'Table: move column right' },

  { { 'n' }, '<A-S-h>', op(function(t)
    if t.col < 2 then return t.row, t.col end
    for _, row in ipairs(t.rows) do row[t.col], row[t.col - 1] = row[t.col - 1], row[t.col] end
    t.aligns[t.col], t.aligns[t.col - 1] = t.aligns[t.col - 1], t.aligns[t.col]
    return t.row, t.col - 1
  end), 'Table: move column left' },

  { { 'n' }, '<A-S-j>', op(function(t)
    if t.row <= t.delim or t.row >= #t.rows then return t.row, t.col end
    t.rows[t.row], t.rows[t.row + 1] = t.rows[t.row + 1], t.rows[t.row]
    return t.row + 1, t.col
  end, multicursor('lineSkipCursor', 1)), 'Table: move row down (outside a table: skip a line downwards)' },

  { { 'n' }, '<A-S-k>', op(function(t)
    if t.row <= t.delim + 1 then return t.row, t.col end
    t.rows[t.row], t.rows[t.row - 1] = t.rows[t.row - 1], t.rows[t.row]
    return t.row - 1, t.col
  end, multicursor('lineSkipCursor', -1)), 'Table: move row up (outside a table: skip a line upwards)' },

  { { 'n' }, '<A-a>', op(function(t)
    local current = t.aligns[t.col] or 'none'
    for i, name in ipairs(alignments) do
      if name == current then
        t.aligns[t.col] = alignments[i % #alignments + 1]
        break
      end
    end
    return t.row, t.col
  end), 'Table: cycle column alignment (none/left/center/right)' },

  { { 'n' }, '<A-t>', new_table, 'Table: insert a new table here' },
}

-- A markdown *file being edited*, not merely a buffer whose filetype is
-- markdown: an LSP hover float, a telescope preview and any plugin scratch
-- window can all be `filetype=markdown` with `buftype=nofile`, and none of
-- them wants <Tab> and <CR> rewired.
local function editable_markdown(buf)
  -- `== true`, not a bare `and` chain: a missing filetype key yields nil, and
  -- nil is not false when this is compared against the attached-maps flag.
  return (table_filetypes[vim.bo[buf].filetype]
    and vim.bo[buf].buftype == ''
    and vim.bo[buf].modifiable) == true
end

-- Matching FileType "*" rather than just markdown, like markdown_edit.lua and
-- for the same reason: a buffer whose filetype changes *away* from markdown
-- has to get these keys taken back off, or <Tab> and <CR> would stay shadowed
-- away from nvim-cmp in a buffer that has no tables in it.
--
-- Only maps this file actually set are removed, tracked by a buffer flag. A
-- blind `keymap.del` would delete some *other* plugin's buffer-local <Tab> or
-- <CR> — telescope's picker keys, for one — in any buffer that sets its
-- filetype after its mappings.
api.nvim_create_autocmd('FileType', {
  callback = function(args)
    local wanted = editable_markdown(args.buf)
    local attached = vim.b[args.buf].markdown_table_maps
    if wanted == (attached == true) then return end

    for _, spec in ipairs(table_maps) do
      local modes, lhs, fn, desc = spec[1], spec[2], spec[3], spec[4]
      for _, mode in ipairs(modes) do
        if wanted then
          vim.keymap.set(mode, lhs, fn, { buffer = args.buf, desc = desc, silent = true })
        else
          pcall(vim.keymap.del, mode, lhs, { buffer = args.buf })
        end
      end
    end
    vim.b[args.buf].markdown_table_maps = wanted or nil
  end,
})

-- Reflow on leaving insert mode as well, so a table stays aligned even when it
-- was edited with plain typing rather than the keys above.
api.nvim_create_autocmd('InsertLeave', {
  callback = function(args)
    if editable_markdown(args.buf) then pcall(reformat) end
  end,
})

vim.api.nvim_create_user_command('TableFormat', function() reformat() end,
  { desc = 'Reflow the markdown table under the cursor' })
