-- nvfuzzy.lua — the editor half of the shell's `nv <pattern>`.
--
-- The shell does not search. It launches nvim straight away and hands the
-- pattern over in NVFUZZY_* env vars; the walk runs *here*, as a job, so the
-- editor is usable from the first frame and hits stream in behind you. That
-- ordering is the whole point of the command: `nv api` in a big tree should
-- feel like opening nvim, not like waiting for find(1).
--
-- What arrives is split in two:
--
--   * the first MAX_TABS hits open as tabs, left of the results tab, and only
--     the *first* one takes the cursor — everything after it lands behind you.
--     A search hit yanking you out of the file you are reading is the thing
--     this avoids.
--   * everything else is listed in the results buffer, which is an ordinary
--     scratch buffer of plain paths — the same argument as `:Yanks` and
--     `:GitReview`: /, n, visual mode, yy, gf and marks all work because it
--     is text, so there is nothing to learn. <CR> on a path opens it in a tab
--     (a directory opens as netrw).
--
-- The results tab is always the **last** tab, so tab 1 is the best hit and the
-- tabline reads best-first, left to right.

local M = {}

local MAX_TABS  = 5    -- hits opened as tabs
local MAX_DEPTH = 50   -- directory levels for a recursive search
local MAX_HITS  = 2000 -- hard stop; a pattern this loose is a mistake, not a search

local state = nil

-- ── searching, breadth-first ───────────────────────────────────────────────
--
-- fd walks depth-first, so in a deep tree the first ten things it prints are
-- whatever directory it descended into first — `init.lua` at the root losing
-- to ten files four levels down. The fix is to search in **depth bands** and
-- release them in order: a band's hits are held until every shallower band has
-- *exited*, so what reaches you is breadth-first.
--
-- The bands stop at 2 because that is where the cost/benefit turns. A band is
-- one more walk of the tree down to its depth, and measured on a pathological
-- home directory (a full 50-level walk there does not finish inside a minute)
-- band 1 costs 0.33s and band 2 costs 0.09s, while in an ordinary repo all of
-- them are ~0.05s. Two shallow bands buy correct ordering for the root and the
-- level under it — where the file you meant almost always is — for a delay
-- bounded by two readdir sweeps. Everything from depth 3 down arrives in walk
-- order, and the *listing* below is ranked regardless.
--
-- Note this is gated on process exits, not on a clock: in a normal repo the
-- deep band is released after ~50ms, which is sooner than any timer worth
-- setting, and in a huge one it waits exactly as long as the shallow sweeps
-- actually take.
local function bands(depth)
  if depth <= 1 then return { { 1, 1 } } end
  if depth == 2 then return { { 1, 1 }, { 2, 2 } } end
  return { { 1, 1 }, { 2, 2 }, { 3, depth } }
end

local function fd_bin()
  for _, b in ipairs({ "fdfind", "fd" }) do
    if vim.fn.executable(b) == 1 then return b end
  end
  return nil
end

-- fd matches the *basename* by default (no --full-path), which is what
-- "matching file names" means here, and its pattern is an unanchored regex —
-- so a plain `api` already behaves as `.*api.*` with no wrapping needed.
local function search_cmd(opts, lo, hi)
  local bin = fd_bin()
  if bin then
    return {
      bin, "--hidden", "--exclude", ".git",
      "--type", opts.dirs and "d" or "f",
      "--min-depth", tostring(lo), "--max-depth", tostring(hi),
      "--ignore-case", "--color", "never",
      "--", opts.pattern, ".",
    }
  end
  -- No fd: find(1) always exists. -iname is a glob, not a regex, so the
  -- substring wrapping that fd got for free has to be written out.
  return {
    "find", ".", "-mindepth", tostring(lo), "-maxdepth", tostring(hi),
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

local function by_rank(a, b)
  if a.score ~= b.score then return a.score > b.score end
  return a.path < b.path
end

local function normalize(line)
  local p = line:gsub("\r$", ""):gsub("^%./", "")
  return p ~= "" and p or nil
end

-- Run the banded search. `on_hit` fires once per hit in release order;
-- `on_progress(hits, truncated, done)` fires whenever there is something new
-- to draw. Returns the job ids so a caller can stop early.
local function run(opts, on_hit, on_progress)
  local bs = bands(opts.depth)
  local seen, hits, jobs, queues, finished = {}, {}, {}, {}, {}
  local released, live, truncated = 0, #bs, false

  local function emit(hit)
    if seen[hit.path] then return end
    if #hits >= MAX_HITS then
      truncated = true
      for _, j in ipairs(jobs) do pcall(vim.fn.jobstop, j) end
      return
    end
    seen[hit.path] = true
    hits[#hits + 1] = hit
    on_hit(hit)
  end

  -- A band is released once every shallower band has exited; from then on its
  -- hits stream straight through. What it had queued up meanwhile is ranked
  -- before it is let out, since by definition it is all in hand at once.
  local function advance()
    local upto = 1
    while finished[upto] do upto = upto + 1 end
    while released < math.min(upto, #bs) do
      released = released + 1
      local q = queues[released]
      queues[released] = nil
      table.sort(q, by_rank)
      for _, h in ipairs(q) do emit(h) end
    end
  end

  for i, band in ipairs(bs) do
    queues[i] = {}
    local job = vim.fn.jobstart(search_cmd(opts, band[1], band[2]), {
      cwd = opts.cwd,
      stdout_buffered = false,
      on_stdout = function(_, data)
        local dirty = false
        for _, line in ipairs(data or {}) do
          local p = normalize(line)
          if p then
            local hit = { path = p, score = score(p, opts.pattern) }
            if queues[i] then queues[i][#queues[i] + 1] = hit else emit(hit) end
            dirty = true
          end
        end
        if dirty then on_progress(hits, truncated, false) end
      end,
      on_exit = function()
        finished[i] = true
        live = live - 1
        advance()
        on_progress(hits, truncated, live == 0)
      end,
    })
    if job > 0 then jobs[#jobs + 1] = job end
  end

  if #jobs == 0 then
    vim.notify("nv: could not start the search", vim.log.levels.ERROR)
    on_progress({}, false, true)
  else
    advance()  -- band 1 has nothing to wait for
  end
  return jobs
end

-- ── tabs ───────────────────────────────────────────────────────────────────

local tab_utils = require("shared.tab_utils")

local function results_tabnr()
  if state and state.results_tab and vim.api.nvim_tabpage_is_valid(state.results_tab) then
    return vim.api.nvim_tabpage_get_number(state.results_tab)
  end
  return vim.fn.tabpagenr("$")
end

-- Open `path` in a tab immediately left of the results tab, keeping the
-- results tab last. Unless `focus`, the cursor goes back where it was —
-- tabpage *and* window, since the results tab can be split and landing in the
-- wrong window of the right tab is as disruptive as landing in the wrong tab.
-- Returns true if a tab was actually opened.
local function open_hit_tab(path, focus)
  if tab_utils.focus_if_open(path) then return false end

  local cur_tab = vim.api.nvim_get_current_tabpage()
  local cur_win = vim.api.nvim_get_current_win()
  local lazy = vim.o.lazyredraw
  vim.o.lazyredraw = true

  local ok, err = pcall(vim.cmd, (results_tabnr() - 1) .. "tabedit " .. vim.fn.fnameescape(path))

  if ok and not focus and vim.api.nvim_tabpage_is_valid(cur_tab) then
    vim.api.nvim_set_current_tabpage(cur_tab)
    if vim.api.nvim_win_is_valid(cur_win) then
      vim.api.nvim_set_current_win(cur_win)
    end
  end

  vim.o.lazyredraw = lazy
  if not ok then
    vim.notify("nv: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

-- ── the results buffer ─────────────────────────────────────────────────────

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function render()
  if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end

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

  -- The tabs were opened as they were released, the listing is ranked, so the
  -- two sets are not "the top N of this list". Name them by what they are.
  local opened, rest = {}, {}
  for _, h in ipairs(state.hits) do
    if state.opened[h.path] then table.insert(opened, h) else table.insert(rest, h) end
  end
  table.sort(opened, by_rank)
  table.sort(rest, by_rank)

  local function section(title, list)
    if #list == 0 then return end
    table.insert(lines, title)
    for _, h in ipairs(list) do
      table.insert(lines, "  " .. h.path)
      map[#lines] = h.path
    end
    table.insert(lines, "")
  end

  section("open in the tabs to the left (" .. #opened .. "):", opened)
  section("also matched (" .. #rest .. "):", rest)

  if state.done and #state.hits == 0 then
    lines[#lines + 1] = "no search results."
    lines[#lines + 1] = ""
    for _, l in ipairs(state.tree or {}) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "<CR> open in a tab  ·  R refresh  ·  q close"

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

  state.results_tab = vim.api.nvim_get_current_tabpage()

  vim.keymap.set("n", "<CR>", function()
    local path = state and state.line_path and state.line_path[vim.fn.line(".")]
    if path then open_hit_tab(path, true) end
  end, { buffer = buf, desc = "nv: open this path in a tab" })

  vim.keymap.set("n", "R", function() M.rerun() end, { buffer = buf, desc = "nv: run the search again" })
  vim.keymap.set("n", "q", close_results, { buffer = buf, desc = "nv: close the results" })

  return buf
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

function M.show(hits, truncated, done)
  if not state then return end
  state.hits, state.truncated, state.done = hits, truncated, done
  if not state.buf then state.buf = setup_buffer() end
  if done and #hits == 0 and not state.tree then
    collect_tree(function(tree) state.tree = tree; render() end)
  end
  render()
end

function M.rerun()
  if not state then return end
  local opts = {
    pattern = state.pattern, dirs = state.dirs,
    depth = state.depth, cwd = state.cwd,
  }
  state.opened, state.tree = {}, nil
  local tabs_opened = 0
  local first_run = not state.ran_once
  state.ran_once = true

  run(opts,
    function(hit)
      if tabs_opened >= MAX_TABS then return end
      -- Only the first hit takes the cursor, and only on the first run: `R`
      -- refreshing a list you are reading must not throw you out of it.
      local focus = first_run and tabs_opened == 0
        and vim.api.nvim_get_current_tabpage() == state.results_tab
      if open_hit_tab(hit.path, focus) then
        state.opened[hit.path] = true
        tabs_opened = tabs_opened + 1
      end
    end,
    M.show)
end

-- -f: open the best hit and nothing else. It still runs as a job so nvim stays
-- responsive, and it stops as soon as the shallowest band that has anything in
-- it is released — with -t (the `nvf` alias) that is the whole search.
local function run_first(opts)
  local best, done, jobs = nil, false, nil

  local function finish()
    if done then return end
    done = true
    for _, j in ipairs(jobs or {}) do pcall(vim.fn.jobstop, j) end
    if best then
      vim.cmd("edit " .. vim.fn.fnameescape(best.path))
    else
      M.show({}, false, true)
    end
  end

  jobs = run(opts,
    function(hit)
      if not best or hit.score > best.score then best = hit end
    end,
    function(_, _, finished)
      -- Stop at the first *released* hit. Releases are breadth-first, so that
      -- hit comes from the shallowest band with anything in it, and a band
      -- that was held long enough to queue up is ranked before it is let out.
      -- Waiting for the rest of a 50-level walk to confirm the winner is
      -- exactly the wait this command exists to avoid.
      if best then finish() end
      if finished then finish() end
    end)
end

function M.start()
  vim.schedule(function()
    local opts = opts_from_env()
    if opts.pattern == "" then return end

    state = {
      pattern = opts.pattern, dirs = opts.dirs, depth = opts.depth, cwd = opts.cwd,
      hits = {}, opened = {}, line_path = {}, done = false, buf = nil,
    }

    if opts.first then
      run_first(opts)
      return
    end

    state.buf = setup_buffer()
    render()
    M.rerun()
  end)
end

return M
