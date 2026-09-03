-- nvfuzzy.lua — the editor half of the shell's `nv <pattern>`.
--
-- The shell does not search. It launches nvim straight away and hands the
-- pattern over in NVFUZZY_* env vars; the walk runs *here*, as a job, so the
-- editor is usable from the first frame and hits stream in behind you. That
-- ordering is the whole point of the command: `nv api` in a big tree should
-- feel like opening nvim, not like waiting for find(1).
--
-- What arrives is deliberately split in two:
--
--   * the first MAX_TABS hits open as **background tabs** — a real tab each,
--     loaded and highlighted, but the cursor never leaves the results tab.
--     A search hit landing on you mid-keystroke is the thing this avoids.
--   * everything else is listed in the results buffer, which is an ordinary
--     scratch buffer of plain paths — the same argument as `:Yanks` and
--     `:GitReview`: /, n, visual mode, yy, gf and marks all work because it
--     is text, so there is nothing to learn. <CR> on a path opens it in a tab
--     next to this one (a directory opens as netrw).
--
-- Ranking and streaming pull against each other -- a rank needs the whole
-- result set, which is the one thing we refuse to wait for -- so the tabs are
-- chosen after a short grace window (see GRACE_MS) rather than from the whole
-- search or from the raw arrival order. The listing below is always ranked,
-- and re-ranks as it grows.

local M = {}

local MAX_TABS  = 10   -- hits opened as background tabs
local MAX_DEPTH = 50   -- directory levels for a recursive search
local MAX_HITS  = 2000 -- hard stop; a pattern this loose is a mistake, not a search

local state = nil

-- ── searching ──────────────────────────────────────────────────────────────

local function fd_bin()
  for _, b in ipairs({ "fdfind", "fd" }) do
    if vim.fn.executable(b) == 1 then return b end
  end
  return nil
end

-- fd matches the *basename* by default (no --full-path), which is what
-- "matching file names" means here, and its pattern is an unanchored regex —
-- so a plain `api` already behaves as `.*api.*` with no wrapping needed.
local function search_cmd(opts)
  local bin = fd_bin()
  if bin then
    return {
      bin, "--hidden", "--exclude", ".git",
      "--type", opts.dirs and "d" or "f",
      "--max-depth", tostring(opts.depth),
      "--ignore-case", "--color", "never",
      "--", opts.pattern, ".",
    }
  end
  -- No fd: find(1) always exists. -iname is a glob, not a regex, so the
  -- substring wrapping that fd got for free has to be written out.
  return {
    "find", ".", "-maxdepth", tostring(opts.depth),
    "-not", "-path", "*/.git/*",
    "-type", opts.dirs and "d" or "f",
    "-iname", "*" .. opts.pattern .. "*",
  }
end

-- Rank a hit against the pattern: an exact basename beats a stem beats a
-- prefix beats a substring, and among equals the shallower path wins. Matched
-- literally on purpose — a pattern carrying regex metacharacters scores flat
-- and falls through to the depth tie-break, which is still a sane order.
local function score(path, pat)
  local base = path:match("[^/]+$") or path
  local lb, lp = base:lower(), pat:lower()
  local stem = lb:gsub("%.[^.]*$", "")
  local s
  if lb == lp then s = 100
  elseif stem == lp then s = 90
  elseif lb:sub(1, #lp) == lp then s = 70
  elseif lb:find(lp, 1, true) then s = 50
  else s = 30 end
  local depth = select(2, path:gsub("/", ""))
  return s * 10000 - depth * 100 - math.min(#base, 99)
end

local function normalize(line)
  local p = line:gsub("\r$", ""):gsub("^%./", "")
  return p ~= "" and p or nil
end

-- ── tabs ───────────────────────────────────────────────────────────────────

local tab_utils = require("shared.tab_utils")

-- Open `path` in a tab after tab number `after` without taking the cursor
-- there. Restoring the tabpage *and* the window matters: the results tab can
-- be split, and landing back in the wrong window of the right tab is as
-- disruptive as landing in the wrong tab.
local function open_tab_after(after, path, focus)
  if tab_utils.focus_if_open(path) then return end

  local cur_tab = vim.api.nvim_get_current_tabpage()
  local cur_win = vim.api.nvim_get_current_win()
  local lazy = vim.o.lazyredraw
  vim.o.lazyredraw = true

  local ok, err = pcall(vim.cmd, after .. "tabedit " .. vim.fn.fnameescape(path))

  if not focus and vim.api.nvim_tabpage_is_valid(cur_tab) then
    vim.api.nvim_set_current_tabpage(cur_tab)
    if vim.api.nvim_win_is_valid(cur_win) then
      vim.api.nvim_set_current_win(cur_win)
    end
  end

  vim.o.lazyredraw = lazy
  if not ok then vim.notify("nv: " .. tostring(err), vim.log.levels.WARN) end
end

-- ── the results buffer ─────────────────────────────────────────────────────

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function render()
  if not (state and vim.api.nvim_buf_is_valid(state.buf)) then return end

  table.sort(state.hits, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.path < b.path
  end)

  local kind = state.dirs and "directories" or "files"
  local scope = state.depth == 1 and "this directory only" or ("depth " .. state.depth)
  local status = state.done and (#state.hits .. " matches") or ("searching… " .. #state.hits .. " so far")
  if state.truncated then status = status .. " (stopped at " .. MAX_HITS .. ")" end

  local lines = {
    ('nv: "%s"  ·  %s  ·  %s  ·  %s'):format(state.pattern, kind, scope, status),
    vim.fn.fnamemodify(state.cwd, ":~"),
    "",
  }
  local map = {}

  local function section(title, from, to)
    if from > to then return end
    table.insert(lines, title)
    for i = from, to do
      table.insert(lines, "  " .. state.hits[i].path)
      map[#lines] = state.hits[i].path
    end
    table.insert(lines, "")
  end

  -- The tabs were opened in arrival order, the listing is ranked, so the two
  -- sets are not "the top N of this list". Name them by what they are.
  local opened, rest = {}, {}
  for _, h in ipairs(state.hits) do
    if state.opened[h.path] then table.insert(opened, h) else table.insert(rest, h) end
  end
  state.hits = {}
  for _, h in ipairs(opened) do table.insert(state.hits, h) end
  local split = #opened
  for _, h in ipairs(rest) do table.insert(state.hits, h) end

  section("open as tabs (" .. split .. "):", 1, split)
  section("also matched (" .. #rest .. "):", split + 1, #state.hits)

  if state.done and #state.hits == 0 then
    lines[#lines + 1] = "no search results."
    lines[#lines + 1] = ""
    for _, l in ipairs(state.tree or {}) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "<CR> open in a tab next to this one  ·  R refresh  ·  q close"

  set_lines(state.buf, lines)
  state.line_path = map
end

-- The tree shown when nothing matched: two levels of the directory you ran in,
-- so the buffer answers "then what *is* here?" instead of just saying no.
local function collect_tree(cb)
  local bin = fd_bin()
  local cmd = bin
    and { bin, "--hidden", "--exclude", ".git", "--max-depth", "2", "--color", "never", ".", "." }
    or  { "find", ".", "-maxdepth", "2", "-not", "-path", "*/.git/*" }
  local out = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, l in ipairs(data or {}) do
        local p = normalize(l)
        if p and #out < 200 then out[#out + 1] = "  " .. p end
      end
    end,
    on_exit = function()
      table.sort(out)
      table.insert(out, 1, "here instead (2 levels):")
      cb(out)
    end,
  })
end

local function close_results()
  if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose")
  elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd("quit")
  else
    vim.cmd("Explore")  -- never exit nvim from a q; same rule as <BS> in remap.lua
  end
end

local function setup_buffer()
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype  = "nvfuzzy"
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.relativenumber = false
  pcall(vim.api.nvim_buf_set_name, buf, "nv: " .. (state and state.pattern or ""))

  local function under_cursor()
    return state and state.line_path and state.line_path[vim.fn.line(".")]
  end

  vim.keymap.set("n", "<CR>", function()
    local path = under_cursor()
    if not path then return end
    open_tab_after(tostring(vim.fn.tabpagenr()), path, true)
  end, { buffer = buf, desc = "nv: open this path in a tab next to the results" })

  vim.keymap.set("n", "R", function() M.rerun() end, { buffer = buf, desc = "nv: run the search again" })
  vim.keymap.set("n", "q", close_results, { buffer = buf, desc = "nv: close the results" })

  return buf
end

-- ── driving a search ───────────────────────────────────────────────────────

local function run(opts, on_hit, on_done)
  local seen, hits, truncated = {}, {}, false
  local job

  local function feed(_, data)
    local dirty = false
    for _, line in ipairs(data or {}) do
      local p = normalize(line)
      if p and not seen[p] then
        seen[p] = true
        if #hits >= MAX_HITS then
          truncated = true
          if job then pcall(vim.fn.jobstop, job) end
          break
        end
        local hit = { path = p, score = score(p, opts.pattern) }
        hits[#hits + 1] = hit
        on_hit(hit)
        dirty = true
      end
    end
    if dirty then on_done(hits, truncated, false) end
  end

  job = vim.fn.jobstart(search_cmd(opts), {
    cwd = opts.cwd,
    stdout_buffered = false,
    on_stdout = feed,
    on_exit = function() on_done(hits, truncated, true) end,
  })

  if job <= 0 then
    vim.notify("nv: could not start the search", vim.log.levels.ERROR)
    on_done({}, false, true)
  end
  return job
end

-- ── entry points ───────────────────────────────────────────────────────────

local function opts_from_env()
  return {
    pattern = os.getenv("NVFUZZY_PATTERN") or "",
    dirs    = os.getenv("NVFUZZY_DIRS") == "1",
    first   = os.getenv("NVFUZZY_FIRST") == "1",
    depth   = os.getenv("NVFUZZY_TOP") == "1" and 1 or MAX_DEPTH,
    cwd     = vim.fn.getcwd(),
  }
end

-- -f: open the best hit and nothing else. It still runs as a job so nvim
-- stays responsive, and it stops early on a perfect basename match — with -t
-- (the `nvf` alias) that is nearly always the first thing fd prints.
local function run_first(opts)
  local best, done, job = nil, false, nil
  local function finish()
    if done then return end
    done = true
    if job then pcall(vim.fn.jobstop, job) end
    if best then
      vim.cmd("edit " .. vim.fn.fnameescape(best.path))
    else
      M.show(opts, {}, false, true)
    end
  end

  job = run(opts,
    function(hit)
      if not best or hit.score > best.score then best = hit end
    end,
    function(_, _, finished)
      if best and best.score >= 100 * 10000 - 9999 then finish() end
      if finished then finish() end
    end)
end

-- Populate/refresh the results buffer. Split out so `R` can reuse it.
function M.show(opts, hits, truncated, done)
  state.hits, state.truncated, state.done = hits, truncated, done
  if not state.buf then state.buf = setup_buffer() end
  if done and #hits == 0 and not state.tree then
    collect_tree(function(tree) state.tree = tree; render() end)
  end
  render()
end

-- How long to hold the first hits back before choosing which become tabs.
-- Long enough that a small tree finishes searching inside it (so the tabs are
-- genuinely the best 10), short enough not to read as latency.
local GRACE_MS = 150

function M.rerun()
  if not state then return end
  local opts = {
    pattern = state.pattern, dirs = state.dirs,
    depth = state.depth, cwd = state.cwd,
  }
  state.opened, state.tree = {}, nil

  -- The tabs would otherwise be the first ten hits fd happens to print, which
  -- in a deep tree is whatever directory it walked into first -- `init.lua` at
  -- the root losing to ten files four levels down. So the opening is held for
  -- GRACE_MS and then ranks what has arrived. A small tree finishes inside the
  -- grace window and gets its true top ten; a big one gets the best of the
  -- first moment, and anything after that is opened in arrival order because
  -- by then there is nothing left to compare it against.
  local pending, flushed = {}, false

  local function open_bg(path)
    state.opened[path] = true
    open_tab_after(tostring(vim.fn.tabpagenr("$")), path, false)
  end

  local function flush()
    if flushed then return end
    flushed = true
    table.sort(pending, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.path < b.path
    end)
    for i = 1, math.min(MAX_TABS, #pending) do open_bg(pending[i].path) end
    pending = {}
  end

  vim.defer_fn(flush, GRACE_MS)

  run(opts,
    function(hit)
      if not flushed then
        pending[#pending + 1] = hit
      elseif vim.tbl_count(state.opened) < MAX_TABS then
        open_bg(hit.path)
      end
    end,
    function(hits, truncated, done)
      if done then flush() end
      M.show(opts, hits, truncated, done)
    end)
end

function M.start()
  vim.schedule(function()
    local opts = opts_from_env()
    if opts.pattern == "" then return end

    if opts.first then
      state = { pattern = opts.pattern, dirs = opts.dirs, depth = opts.depth,
                cwd = opts.cwd, hits = {}, opened = {}, line_path = {} }
      state.buf = nil
      run_first(opts)
      return
    end

    state = {
      pattern = opts.pattern, dirs = opts.dirs, depth = opts.depth, cwd = opts.cwd,
      hits = {}, opened = {}, line_path = {}, done = false,
    }
    state.buf = setup_buffer()
    render()
    M.rerun()
  end)
end

return M
