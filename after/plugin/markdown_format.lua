-- markdown_format.lua — :MarkdownFormat, the aggressive markdown reformatter.
--
-- The formatting itself is `lua/shared/markdown_format.lua`, which is pure and
-- headlessly testable; this file is the buffer half: the range, the cursor,
-- and the two buffers that must not be reflowed.
--
--   :MarkdownFormat           the whole buffer
--   :'<,'>MarkdownFormat      just the selection (also `:10,40MarkdownFormat`)
--   :MarkdownFormat!          bang = do it anyway on an opted-out buffer
--   <leader>m=                the whole buffer / the selection
--
-- It is a command and not a formatter in `after/plugin/conform.lua`, because
-- unwrapping every paragraph in a document is a large edit in one direction
-- and it should happen when you ask for it, not on every :w. prettier still
-- runs on save and leaves this output alone (proseWrap defaults to
-- "preserve"), with one difference worth knowing: prettier also rewrites
-- `*emphasis*` to `_emphasis_`, which this does not, so the first save after
-- a format may show that one extra change. Inline rewriting is left to
-- prettier on purpose — it needs a real inline parser to avoid eating code
-- spans, and there is already one in the pipeline doing it correctly.

local formatter = require('shared.markdown_format')

-- The cursor is kept on the same *text*, not the same line number: unwrapping
-- moves every line in the document, so a line number means nothing across the
-- edit. Counting non-whitespace characters does survive it, because that is
-- the one thing reflowing does not change.
local function char_offset(lines, row, col)
  local n = 0
  for i = 1, math.min(row - 1, #lines) do
    n = n + #(lines[i]:gsub('%s', ''))
  end
  if lines[row] then
    n = n + #(lines[row]:sub(1, col):gsub('%s', ''))
  end
  return n
end

local function offset_to_pos(lines, target)
  local n = 0
  for i, line in ipairs(lines) do
    local bare = #(line:gsub('%s', ''))
    if n + bare >= target then
      -- Walk the line to find the column holding the target character.
      local seen = n
      for c = 1, #line do
        if not line:sub(c, c):match('%s') then
          seen = seen + 1
          if seen >= target then
            return i, c
          end
        end
      end
      return i, math.max(0, #line)
    end
    n = n + bare
  end
  return math.max(1, #lines), 0
end

local function run(opts)
  local buf = vim.api.nvim_get_current_buf()

  -- :GitReview's document is an editable markdown file whose exact line shape
  -- is parsed back on the next render to recover the review boxes and the
  -- comments under each diff. Reflowing it loses them, so the flag that keeps
  -- prettier off it keeps this off too — bang overrides, as always.
  if vim.b[buf].no_autoformat and not opts.bang then
    vim.notify(
      'MarkdownFormat: this buffer is marked no_autoformat (:GitReview parses its shape back). '
        .. 'Use :MarkdownFormat! to format it anyway.',
      vim.log.levels.WARN
    )
    return
  end

  -- -range=% makes "no range" mean the whole buffer, so there is nothing to
  -- distinguish here: line1/line2 are always the region to format.
  local first, last = opts.line1, opts.line2
  local region = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local in_region = cursor[1] >= first and cursor[1] <= last
  local offset = in_region and char_offset(region, cursor[1] - first + 1, cursor[2]) or nil

  local ok, formatted = pcall(formatter.format, region)
  if not ok then
    vim.notify('MarkdownFormat: ' .. tostring(formatted), vim.log.levels.ERROR)
    return
  end

  if vim.deep_equal(region, formatted) then
    vim.notify('MarkdownFormat: already formatted')
    return
  end

  vim.api.nvim_buf_set_lines(buf, first - 1, last, false, formatted)

  if offset then
    local row, col = offset_to_pos(formatted, offset)
    row = math.min(first + row - 1, vim.api.nvim_buf_line_count(buf))
    local width = #(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or '')
    pcall(vim.api.nvim_win_set_cursor, 0, { row, math.min(col, math.max(0, width - 1)) })
  end

  local scope = (first == 1 and last >= #region) and '' or (' (lines ' .. first .. '-' .. last .. ')')
  vim.notify(('MarkdownFormat: %d → %d lines%s'):format(#region, #formatted, scope))
end

vim.api.nvim_create_user_command('MarkdownFormat', run, {
  range = '%',
  bang = true,
  desc = 'Reformat markdown: unwrap prose, one blank line between blocks, even tables',
})

vim.keymap.set('n', '<leader>m=', '<Cmd>MarkdownFormat<CR>', { desc = 'Format markdown (whole buffer)' })
vim.keymap.set('x', '<leader>m=', ':MarkdownFormat<CR>', { desc = 'Format markdown (selection)' })
