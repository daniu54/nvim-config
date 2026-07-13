-- Interactive mode: notebook-style execution of shell instructions inside a
-- buffer. Enable per-buffer with :InteractiveMode, then write a line like
--   /ls -la
-- Once run, the line is prefixed with "##" and an output region is left in
-- place:
--   ## /ls -la
--   ``` process 12345
--   ...last lines...
--   ``` end 12345
local parser = require("interactive.parser")
local job = require("interactive.job")
local region = require("interactive.region")

local M = {}

local claim_ns = vim.api.nvim_create_namespace("interactive_claim")
local DEBOUNCE_MS = 300

local debounce_timers = {} -- bufnr -> uv_timer

local function is_claimed(bufnr, row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, claim_ns, { row, 0 }, { row, -1 }, {})
  return #marks > 0
end

-- While the cursor is still sitting on the line (in any window showing this
-- buffer), the user is presumably still typing it out - don't claim or run
-- it yet. Left unclaimed, it's picked up by the next scan once the cursor
-- moves away.
local function cursor_on_row(bufnr, row)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      if vim.api.nvim_win_get_cursor(win)[1] - 1 == row then
        return true
      end
    end
  end
  return false
end

local function run(bufnr, row, instr)
  local custom = parser.custom_commands[instr.name]
  local cmd_text = custom and custom(instr) or instr.raw
  local cwd = vim.fn.expand("#" .. bufnr .. ":p:h")

  local instr_region -- set once job.start returns, read by the async callbacks below

  local job_id, pid = job.start(bufnr, cmd_text, cwd, instr.lines,
    function(lines)
      if instr_region then
        region.update(bufnr, instr_region, lines)
      end
    end,
    function(lines)
      if instr_region then
        region.update(bufnr, instr_region, lines)
        region.finalize(bufnr, instr_region)
      end
    end)

  if not job_id then
    return
  end
  instr_region = region.create(bufnr, row, pid)
end

-- Scans top to bottom; a line only ever gets claimed once (marked via
-- claim_ns), so re-scanning after every edit is safe and idempotent.
local function scan(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].interactive_mode then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for row = 0, line_count - 1 do
    if not is_claimed(bufnr, row) and not cursor_on_row(bufnr, row) then
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      local instr = line and parser.parse(line)
      if instr then
        vim.api.nvim_buf_set_extmark(bufnr, claim_ns, row, 0, {})
        run(bufnr, row, instr)
      end
    end
  end
end

local function schedule_scan(bufnr)
  local timer = debounce_timers[bufnr]
  if not timer then
    timer = vim.uv.new_timer()
    debounce_timers[bufnr] = timer
  end
  timer:start(DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      scan(bufnr)
    end)
  end)
end

-- Fires on :q/:bd/:bw (BufUnload/BufWipeout) for this buffer specifically,
-- so quitting one interactive buffer doesn't touch jobs from another. The
-- VimLeavePre in M.setup() below is the blanket fallback for :qa.
local function cleanup_buffer(bufnr)
  job.stop_for_buffer(bufnr)
  local timer = debounce_timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    debounce_timers[bufnr] = nil
  end
end

function M.enable(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  if vim.b[bufnr].interactive_mode then
    vim.notify("[interactive] already enabled for this buffer", vim.log.levels.INFO)
    return
  end
  vim.b[bufnr].interactive_mode = true

  local group = vim.api.nvim_create_augroup("interactive_buf_" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      schedule_scan(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      cleanup_buffer(bufnr)
    end,
  })

  schedule_scan(bufnr)
  vim.notify("[interactive] enabled", vim.log.levels.INFO)
end

function M.setup()
  vim.api.nvim_create_user_command("InteractiveMode", function()
    M.enable(0)
  end, { desc = "Enable interactive (notebook-style) execution for this buffer" })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      job.stop_all()
    end,
  })
end

return M
