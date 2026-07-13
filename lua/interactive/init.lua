-- Interactive mode: notebook-style execution of shell instructions inside a
-- buffer. Enable per-buffer with :InteractiveMode, then write a line like
--   /ls -la
-- Once run, the line is prefixed with "##" and an output region is left in
-- place:
--   ## /ls -la
--   ``` process 12345
--   ...last lines...
--   ``` end 12345
--
-- A multi-line string can be passed to a command by wrapping it in "''":
--   /echo "line one''
--   line two
--   line three"''
-- See parser.marker_count for how the span is detected.
--
-- A still-running instruction can be killed by commenting it out - prefix
-- its line with a single "#" (not "##", which means "finished"):
--   # /sleep 300
local parser = require("interactive.parser")
local job = require("interactive.job")
local region = require("interactive.region")

local M = {}

local claim_ns = vim.api.nvim_create_namespace("interactive_claim")
-- Every TextChanged/CursorMoved event restarts this timer, so it doubles as
-- the grace period between the cursor actually leaving an instruction's
-- line and that instruction firing - a brief flick of the cursor off the
-- line and back (e.g. an arrow-key typo) won't trigger a run.
local DEBOUNCE_MS = 600

local debounce_timers = {} -- bufnr -> uv_timer
local running = {} -- job_id -> { bufnr, instr_region } - only entries for still-running jobs

local function is_claimed(bufnr, row)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, claim_ns, { row, 0 }, { row, -1 }, {})
  return #marks > 0
end

-- A single leading "#" requests a kill; "##" (finalize's own "done" prefix)
-- must not be mistaken for it - "^#%s" already can't match "## " (its
-- second character is "#", not whitespace), but lines like "#/cmd" (no
-- space) are also accepted, so check that case explicitly too.
local function is_kill_marker(line)
  return line:match("^#") ~= nil and line:match("^##") == nil
end

-- Runs on every scan (cheap: only ever as many entries as running jobs).
-- Unlike scan()'s claim-based logic, this targets rows that are already
-- claimed (they're running), so the two never fight over the same row.
local function check_kills(bufnr)
  for job_id, entry in pairs(running) do
    if entry.bufnr == bufnr then
      local line = region.instr_line(bufnr, entry.instr_region)
      if line and is_kill_marker(line) then
        job.kill(job_id)
        running[job_id] = nil
      end
    end
  end
end

-- While the cursor is still sitting somewhere in [start_row, end_row] (in
-- any window showing this buffer), the user is presumably still typing -
-- don't claim or run it yet. Left unclaimed, it's picked up by the next
-- scan once the cursor moves away.
local function cursor_in_range(bufnr, start_row, end_row)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      if row >= start_row and row <= end_row then
        return true
      end
    end
  end
  return false
end

-- output_row is where the output region is anchored; for multi-line
-- instructions that's the last physical line, not the (earlier) start row.
local function run(bufnr, row, instr, output_row)
  local custom = parser.custom_commands[instr.name]
  local cmd_text = custom and custom(instr) or instr.raw
  local cwd = vim.fn.expand("#" .. bufnr .. ":p:h")

  local instr_region -- set once job.start returns, read by the async callbacks below
  local job_id -- forward-declared: the on_done closure below must close over
  -- this same local, not create/reference an unrelated one - a plain
  -- `local job_id, pid = job.start(...)` would evaluate the RHS (and build
  -- these closures) before the new local's scope even begins.

  local pid
  job_id, pid = job.start(bufnr, cmd_text, cwd, instr.lines,
    function(lines)
      if instr_region then
        region.update(bufnr, instr_region, lines)
      end
    end,
    function(lines)
      running[job_id] = nil
      if instr_region then
        region.update(bufnr, instr_region, lines)
        region.finalize(bufnr, instr_region)
      end
    end)

  if not job_id then
    return
  end
  instr_region = region.create(bufnr, row, pid, output_row)
  running[job_id] = { bufnr = bufnr, instr_region = instr_region }
end

-- Finds where an instruction starting at start_row ends: if first_line_rest
-- (the text after the leading "/") leaves an odd number of "''" markers
-- open, keep consuming lines until the running count is even again. Returns
-- nil if the buffer ends while still open (instruction not finished yet).
local function find_multiline_end(bufnr, start_row, first_line_rest, line_count)
  local parity = parser.marker_count(first_line_rest) % 2
  if parity == 0 then
    return start_row
  end
  local row = start_row + 1
  while row < line_count do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    parity = (parity + parser.marker_count(line)) % 2
    if parity == 0 then
      return row
    end
    row = row + 1
  end
  return nil
end

-- Scans top to bottom; a line only ever gets claimed once (marked via
-- claim_ns), so re-scanning after every edit is safe and idempotent. Uses an
-- explicit row cursor (rather than a for loop) so multi-line instructions
-- can be skipped over as a unit instead of having their body lines
-- re-examined as standalone instructions.
local function scan(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.b[bufnr].interactive_mode then
    return
  end
  check_kills(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = 0
  while row < line_count do
    if is_claimed(bufnr, row) then
      row = row + 1
    else
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      local rest = line and not line:match("^##%s") and line:match("^/(.+)$")
      if rest then
        local end_row = find_multiline_end(bufnr, row, rest, line_count)
        if not end_row then
          -- "''" still open (closing marker not typed yet); everything
          -- below is presumptively inside it, so stop scanning this pass.
          break
        end
        if not cursor_in_range(bufnr, row, end_row) then
          local instr
          if end_row == row then
            instr = parser.parse(line)
          else
            local body = vim.api.nvim_buf_get_lines(bufnr, row, end_row + 1, false)
            body[1] = rest
            instr = parser.parse_multiline(body)
          end
          if instr then
            for r = row, end_row do
              vim.api.nvim_buf_set_extmark(bufnr, claim_ns, r, 0, {})
            end
            -- run() inserts the (2-line) output region synchronously,
            -- shifting every row below it - reconcile row/line_count against
            -- that shift so later instructions in this same pass aren't
            -- skipped over.
            local before = line_count
            run(bufnr, row, instr, end_row)
            line_count = vim.api.nvim_buf_line_count(bufnr)
            row = end_row + 1 + (line_count - before)
          else
            row = end_row + 1
          end
        else
          row = end_row + 1
        end
      else
        row = row + 1
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
