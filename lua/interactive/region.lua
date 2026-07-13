-- Tracks each instruction's output region via extmarks, so its location
-- stays correct as the user keeps editing the rest of the buffer above,
-- below, or between concurrently-running regions.
local M = {}

local ns = vim.api.nvim_create_namespace("interactive_region")

-- Neovim's own cursor-follows-edit behavior on nvim_buf_set_lines is
-- inconsistent between the current window and other windows showing the
-- same buffer (see neovim/neovim#27720, #22107). Rather than special-case
-- that, track every window's cursor with a temporary extmark across the
-- edit and re-apply its resolved position afterwards - that's correct
-- regardless of whatever Neovim did or didn't do on its own.
local function with_cursors_preserved(bufnr, fn)
  local marks = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local cursor = vim.api.nvim_win_get_cursor(win)
      marks[win] = vim.api.nvim_buf_set_extmark(bufnr, ns, cursor[1] - 1, cursor[2], {})
    end
  end

  fn()

  for win, mark_id in pairs(marks) do
    if vim.api.nvim_win_is_valid(win) then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark_id, {})
      if pos[1] then
        local row = math.min(pos[1] + 1, vim.api.nvim_buf_line_count(bufnr))
        pcall(vim.api.nvim_win_set_cursor, win, { row, pos[2] })
      end
    end
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark_id)
  end
end

-- output_row defaults to instr_row (single-line instructions); multi-line
-- instructions pass their last physical row instead, so the output lands
-- after the whole instruction rather than right after its first line.
function M.create(bufnr, instr_row, pid, output_row)
  output_row = output_row or instr_row
  local start_line = "``` process " .. pid
  local end_line = "``` end " .. pid
  with_cursors_preserved(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, output_row + 1, output_row + 1, false, { start_line, end_line })
  end)

  return {
    -- right_gravity = false: a *whole-line* replace at this row (e.g. the
    -- user commenting the instruction out via a full-line edit) is a
    -- delete-then-insert at the same position; a default right-gravity mark
    -- would get pushed past the freshly inserted line onto the row below it
    -- instead of staying anchored to its own line.
    instr_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, instr_row, 0, { right_gravity = false }),
    start_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, output_row + 1, 0, {}),
    end_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, output_row + 2, 0, {}),
  }
end

function M.update(bufnr, region, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local start_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, region.start_mark, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, region.end_mark, {})
  if not start_pos[1] or not end_pos[1] then
    return
  end

  local content_start = start_pos[1] + 1
  local content_end = end_pos[1]
  local old_count = content_end - content_start
  local new_count = #lines

  if old_count == new_count then
    local current = vim.api.nvim_buf_get_lines(bufnr, content_start, content_end, false)
    if vim.deep_equal(current, lines) then
      return
    end
  end

  with_cursors_preserved(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, content_start, content_end, false, lines)
  end)
end

-- Current text of a region's instruction line (nil if the buffer/mark is
-- gone). Used to notice the user has edited a still-running instruction,
-- e.g. to comment it out and request a kill.
function M.instr_line(bufnr, region)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, region.instr_mark, {})
  if not pos[1] then
    return nil
  end
  return vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)[1]
end

-- The full row range a region currently occupies, from its instruction line
-- through its "``` end" line (nil if the buffer/marks are gone). Used to
-- tell whether the cursor is anywhere inside a running instruction's
-- footprint, e.g. to focus its live terminal.
function M.extent(bufnr, region)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local instr_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, region.instr_mark, {})
  local end_pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, region.end_mark, {})
  if not instr_pos[1] or not end_pos[1] then
    return nil
  end
  return instr_pos[1], end_pos[1]
end

function M.finalize(bufnr, region)
  if vim.api.nvim_buf_is_valid(bufnr) then
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, region.instr_mark, {})
    if pos[1] then
      local row = pos[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if line and not line:match("^##%s") then
        with_cursors_preserved(bufnr, function()
          vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { "## " .. line })
        end)
      end
    end
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, region.instr_mark)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, region.start_mark)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, region.end_mark)
  end
end

return M
