-- table_cell_hint.lua — the label and the highlight drawn on the table cell
-- the cursor is in.
--
-- Two consumers, one look: markdown tables (after/plugin/markdown_table.lua)
-- and csv/tsv files (after/plugin/csvview.lua). Both answer the same problem —
-- a table wide or long enough to scroll its header row out of the window
-- leaves the cell you are typing in as a bare string with nothing saying what
-- it is a value of — so both get the same answer:
--
--     name,age,city
--     bob,12 age,rom
--          ^^ gold ^^^ muted
--
-- The cell's own text in gold, the column's header muted right after it. There
-- are no brackets around the label: the colour split is what separates value
-- from annotation, which is why the two marks come as a pair.
--
-- Both are **extmarks**, so this is virtual text in the strict sense — not in
-- the buffer, not in the file, not selectable, not yanked, invisible to `$`,
-- to the formatter and to every line-text reader on either side. That is why
-- the label can sit on a line markdown_table.lua rewrites on every keystroke
-- with no coordination between the two: the line is replaced, nvim moves the
-- mark, and the next cursor move redraws it regardless.
--
-- The label is `inline`, not `eol`, because it belongs to one cell rather than
-- to a row of five — **and inline virtual text pushes the rest of the row
-- right**, so the cell borders past the cursor stop lining up with the rows
-- above and below while the label is up, and snap back when the cursor leaves.
-- That jostling is accepted on purpose.
local M = {}

local api = vim.api

local ns = api.nvim_create_namespace('table_cell_hint')

-- Long headers are labels, not content: a 60-column one shoved into the middle
-- of a row is noise, and the first few words identify the column anyway.
local MAX_HEADER = 40

-- `:TableHeaderHint` toggles this for every consumer at once — it is one
-- feature wearing two filetypes, so it has one switch.
M.enabled = true

local updaters = {}

function M.clear(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

--- Draw the pair on one cell. `row` is 0-based; `from`/`to` are 0-based byte
--- columns bounding the cell's *text* — not the padding around it, so the
--- colour lands on the value and the label sits against it. A zero-width range
--- (an empty cell) gets the label only.
---@param buf integer
---@param row integer
---@param from integer
---@param to integer
---@param header string
function M.show(buf, row, from, to, header)
  if not M.enabled or header == nil or header == '' then return end
  if vim.fn.strwidth(header) > MAX_HEADER then
    header = vim.fn.strcharpart(header, 0, MAX_HEADER - 1) .. '…'
  end

  if to > from then
    api.nvim_buf_set_extmark(buf, ns, row, from, {
      end_col = to,
      hl_group = 'MarkdownTableCurrentCell',
    })
  end

  api.nvim_buf_set_extmark(buf, ns, row, to, {
    virt_text = { { ' ' .. header, 'MarkdownTableHeaderHint' } },
    virt_text_pos = 'inline',
    hl_mode = 'combine',
  })
end

--- Register a redraw function, so the toggle can put the label back on the
--- buffer in front of you without waiting for the next cursor move. Each one
--- decides for itself whether the buffer is its business.
---@param fn fun(buf: integer)
function M.register(fn)
  updaters[#updaters + 1] = fn
end

function M.toggle()
  M.enabled = not M.enabled
  local buf = api.nvim_get_current_buf()
  M.clear(buf)
  if M.enabled then
    for _, fn in ipairs(updaters) do pcall(fn, buf) end
  end
  vim.notify('Table header hint ' .. (M.enabled and 'on' or 'off'))
end

return M
