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

M.jobs = {} -- job_id -> { bufnr, term_buf, timer, host_win, host_tab }

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

-- A terminal buffer's actual rendering grid (what its lines mirror, distinct
-- from the PTY's ioctl window size) is sized from whichever window is
-- displaying it *at creation time*, and jobresize() alone does not grow it
-- afterwards - confirmed by testing that a never-displayed terminal stays
-- pinned to a small default grid (5 rows in a headless run) no matter what
-- jobresize() is told, even though the PTY-level size it reports to the
-- child process (e.g. via `stty size`) does update correctly. A full-screen
-- TUI's actual on-screen size is dictated by that grid, not the PTY ioctl,
-- so it renders cramped even though the child "knows" the bigger size.
--
-- Fix: host the buffer in a real floating window sized to the desired
-- viewport before starting the job, and keep that window open for the job's
-- whole lifetime - closing it stops the terminal from updating its buffer
-- content at all (tested: content freezes blank), so it can't be a
-- create-then-close step.
--
-- The window lives on its own tabpage, created and immediately switched
-- away from, rather than as a blended/unfocusable float over the current
-- tab: a `winblend = 100` float (tried first) only blends *colors*, not
-- glyphs, so a dense TUI's box-drawing characters and text still visibly
-- painted over the user's buffer just with washed-out colors - genuinely
-- ugly in practice despite testing clean in a headless (visually-unverifiable)
-- run. A background tabpage has no such problem: Neovim only ever draws the
-- *current* tab's layout, so a window sitting on a tab you're not on is
-- never drawn at all, full stop - no blending trickery needed. The
-- create/switch-back (and later, close) round trips happen synchronously
-- with 'eventignore' set, so no autocmd or visible redraw happens in
-- between.
--
-- An oversized size request is silently clamped to the real screen size by
-- Neovim (tested: no error, nvim_win_get_height reports the clamped value)
-- - no manual clamping needed, but the clamped size is read back so PTY
-- sizing and tail polling stay consistent with what the grid can actually
-- hold.
local function open_host_win(term_buf, viewport_lines)
  local orig_tab = vim.api.nvim_get_current_tabpage()
  local orig_ei = vim.o.eventignore
  vim.o.eventignore = "all"

  vim.cmd("tabnew")
  local host_tab = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_open_win(term_buf, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = VIEWPORT_COLS,
    height = viewport_lines,
    style = "minimal",
    border = "none",
  })
  local cols, rows = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)

  vim.api.nvim_set_current_tabpage(orig_tab)
  vim.o.eventignore = orig_ei

  return win, host_tab, cols, rows
end

-- Closes a job's hidden tabpage (and every window on it, including the
-- leftover blank window `tabnew` itself created). Briefly switches to it to
-- run `:tabclose` (there's no tabpage-targeted API equivalent), then
-- switches back - wrapped in 'eventignore' like open_host_win, so this is
-- as invisible/side-effect-free as the creation round trip.
local function close_host_tab(host_tab)
  if not (host_tab and vim.api.nvim_tabpage_is_valid(host_tab)) then
    return
  end
  local orig_tab = vim.api.nvim_get_current_tabpage()
  local orig_ei = vim.o.eventignore
  vim.o.eventignore = "all"

  vim.api.nvim_set_current_tabpage(host_tab)
  pcall(vim.cmd, "tabclose")
  if vim.api.nvim_tabpage_is_valid(orig_tab) then
    vim.api.nvim_set_current_tabpage(orig_tab)
  end

  vim.o.eventignore = orig_ei
end

-- on_output(lines) fires periodically while the job runs.
-- on_done(lines, exit_code) fires once, after the job exits.
function M.start(bufnr, cmd_text, cwd, viewport_lines, on_output, on_done)
  viewport_lines = viewport_lines or DEFAULT_VIEWPORT_LINES
  local term_buf = vim.api.nvim_create_buf(false, true)
  local host_win, host_tab, cols, rows = open_host_win(term_buf, viewport_lines)
  local job_id

  vim.api.nvim_buf_call(term_buf, function()
    job_id = vim.fn.jobstart({ "zsh", "-ic", cmd_text }, {
      term = true,
      cwd = cwd,
      on_exit = function(id, code)
        stop_polling(id)
        vim.schedule(function()
          local lines = tail(term_buf, rows)
          on_done(lines, code)
          close_host_tab(host_tab)
          if vim.api.nvim_buf_is_valid(term_buf) then
            vim.api.nvim_buf_delete(term_buf, { force = true })
          end
          M.jobs[id] = nil
        end)
      end,
    })
  end)

  if not job_id or job_id <= 0 then
    close_host_tab(host_tab)
    vim.api.nvim_buf_delete(term_buf, { force = true })
    return nil
  end

  -- Also pin the PTY ioctl size to match the grid, so the child process's
  -- own notion of terminal size (COLUMNS/LINES, `stty size`, etc.) agrees
  -- with what's actually captured.
  pcall(vim.fn.jobresize, job_id, cols, rows)

  local pid = vim.fn.jobpid(job_id)

  local timer = vim.uv.new_timer()
  timer:start(POLL_MS, POLL_MS, function()
    vim.schedule(function()
      on_output(tail(term_buf, rows))
    end)
  end)

  M.jobs[job_id] = { bufnr = bufnr, term_buf = term_buf, timer = timer, host_win = host_win, host_tab = host_tab }
  return job_id, pid
end

local function stop_job(job_id, job)
  stop_polling(job_id)
  pcall(vim.fn.jobstop, job_id)
  close_host_tab(job.host_tab)
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
