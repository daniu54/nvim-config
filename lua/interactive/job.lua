-- Spawns instructions as real PTY jobs (libvterm-backed terminal buffers),
-- but the buffers are never displayed in any window. This gets us
-- human-readable, escape-code-free output (libvterm has already parsed the
-- ANSI) and correct handling of full-screen/TUI repaints for free: Neovim
-- doesn't keep scrollback for the alternate screen, so a TUI program's
-- terminal buffer content IS its current frame, continuously overwritten.
-- Reading the tail of that buffer is "the last N lines as if watching a
-- terminal" in both the scrolling-output case and the TUI case, uniformly.
--
-- Commands run through an interactive zsh (`zsh -ic <cmd>`), mirroring the
-- nvim-terminal-to-zsh setup: aliases and functions from ~/.zshrc (e.g.
-- `ttv`, `cheat`) resolve, the same as if typed at a real prompt.
local M = {}

M.jobs = {} -- job_id -> { bufnr, term_buf, timer }

local DEFAULT_VIEWPORT_LINES = 50
local VIEWPORT_COLS = 100
local POLL_MS = 150

local function tail(term_buf, viewport_lines)
  if not vim.api.nvim_buf_is_valid(term_buf) then
    return {}
  end
  local count = vim.api.nvim_buf_line_count(term_buf)
  local start = math.max(0, count - viewport_lines)
  local lines = vim.api.nvim_buf_get_lines(term_buf, start, count, false)
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function stop_polling(job_id)
  local job = M.jobs[job_id]
  if job and job.timer then
    job.timer:stop()
    job.timer:close()
    job.timer = nil
  end
end

-- on_output(lines) fires periodically while the job runs.
-- on_done(lines, exit_code) fires once, after the job exits.
function M.start(bufnr, cmd_text, cwd, viewport_lines, on_output, on_done)
  viewport_lines = viewport_lines or DEFAULT_VIEWPORT_LINES
  local term_buf = vim.api.nvim_create_buf(false, true)
  local job_id

  vim.api.nvim_buf_call(term_buf, function()
    job_id = vim.fn.jobstart({ "zsh", "-ic", cmd_text }, {
      term = true,
      cwd = cwd,
      on_exit = function(id, code)
        stop_polling(id)
        vim.schedule(function()
          local lines = tail(term_buf, viewport_lines)
          on_done(lines, code)
          if vim.api.nvim_buf_is_valid(term_buf) then
            vim.api.nvim_buf_delete(term_buf, { force = true })
          end
          M.jobs[id] = nil
        end)
      end,
    })
  end)

  if not job_id or job_id <= 0 then
    vim.api.nvim_buf_delete(term_buf, { force = true })
    return nil
  end

  -- Never displayed in a window, so the PTY size defaults to whatever
  -- Neovim picks for an invisible terminal; pin it to our desired viewport
  -- explicitly rather than relying on that default.
  pcall(vim.fn.jobresize, job_id, VIEWPORT_COLS, viewport_lines)

  local pid = vim.fn.jobpid(job_id)

  local timer = vim.uv.new_timer()
  timer:start(POLL_MS, POLL_MS, function()
    vim.schedule(function()
      on_output(tail(term_buf, viewport_lines))
    end)
  end)

  M.jobs[job_id] = { bufnr = bufnr, term_buf = term_buf, timer = timer }
  return job_id, pid
end

local function stop_job(job_id, job)
  stop_polling(job_id)
  pcall(vim.fn.jobstop, job_id)
  if job.term_buf and vim.api.nvim_buf_is_valid(job.term_buf) then
    pcall(vim.api.nvim_buf_delete, job.term_buf, { force = true })
  end
end

-- Called when a single buffer is unloaded/wiped (:q, :bd, ...) so its jobs
-- die with it without touching other interactive buffers still running.
function M.stop_for_buffer(bufnr)
  for job_id, job in pairs(M.jobs) do
    if job.bufnr == bufnr then
      stop_job(job_id, job)
      M.jobs[job_id] = nil
    end
  end
end

function M.stop_all()
  for job_id, job in pairs(M.jobs) do
    stop_job(job_id, job)
  end
  M.jobs = {}
end

-- Requests termination but, unlike stop_job/stop_for_buffer/stop_all above,
-- does NOT force-cleanup term_buf itself - the normal on_exit handler
-- registered in M.start still runs, so on_output/on_done fire exactly as on
-- natural completion (freezing the region at the last captured output
-- instead of blanking it). Used for a single targeted kill (e.g. the user
-- commenting out a running instruction's line) while Neovim keeps running,
-- as opposed to the bulk-teardown paths above where waiting on that async
-- callback isn't safe (:qa is tearing everything down; :bwipeout may have
-- already invalidated the buffer we'd write the finalized output into).
function M.kill(job_id)
  if M.jobs[job_id] then
    pcall(vim.fn.jobstop, job_id)
  end
end

return M
