-- nvfuzzy.lua — the editor half of the shell's `nv <pattern>`.
--
-- The shell does not search. It launches nvim straight away and hands the
-- pattern over in NVFUZZY_* env vars; the walk runs *here*, as a job, so the
-- editor is usable from the first frame and hits stream in behind you. That
-- ordering is the whole point of the command: `nv api` in a big tree should
-- feel like opening nvim, not like waiting for find(1).
--
-- The pattern is a **subsequence** of the file name: `nv evenapi` finds
-- LinkedInEventsApi.kt. See to_regex below.
--
-- What arrives is split in two:
--
--   * the first MAX_TABS hits open as tabs, left of the results tab, and only
--     the *first* one takes the cursor — everything after it lands behind you.
--     A search hit yanking you out of the file you are reading is the thing
--     this avoids. When the search ends the tab set settles onto the real
--     best MAX_TABS, sorted best-first (see settle_tabs).
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

-- The pattern is a **subsequence** of the file name, not a substring: the
-- characters have to appear in order, but not together. `evenapi` finds
-- LinkedInEventsApi.kt. fd matches the *basename* by default (no
-- --full-path), which is what "matching file names" means here, and its
-- pattern is an unanchored regex — so this is just `e.*v.*e.*n.*a.*p.*i`, run
-- by fd's own engine rather than filtered afterwards in Lua.
--
-- Only a plain pattern is expanded. Anything with a character that is not a
-- letter, digit, `_`, `.` or `-` is handed to fd verbatim, which is the escape
-- hatch when you actually want to write a regex.
local function to_regex(pat)
  if not pat:match("^[%w_.%-]+$") then return pat end
  local parts = {}
  for ch in pat:gmatch(".") do
    parts[#parts + 1] = ch:match("[%w_]") and ch or ("\\" .. ch)
  end
  return table.concat(parts, ".*")
end

-- The same thing as a glob, for the find(1) fallback: `*e*v*e*n*a*p*i*`.
local function to_glob(pat)
  if not pat:match("^[%w_.%-]+$") then return "*" .. pat .. "*" end
  return "*" .. pat:gsub(".", "%0*")
end

local function search_cmd(opts, lo, hi)
  local bin = fd_bin()
  if bin then
    return {
      bin, "--hidden", "--exclude", ".git",
      "--type", opts.dirs and "d" or "f",
      "--min-depth", tostring(lo), "--max-depth", tostring(hi),
      "--ignore-case", "--color", "never",
      "--", to_regex(opts.pattern), ".",
    }
  end
  -- No fd: find(1) always exists. -iname is a glob, so the same subsequence
  -- falls out of putting a `*` between every character.
  return {
    "find", ".", "-mindepth", tostring(lo), "-maxdepth", tostring(hi),
    "-not", "-path", "*/.git/*",
    "-type", opts.dirs and "d" or "f",
    "-iname", to_glob(opts.pattern),
  }
end

-- The tightest run of `s` that contains `p` as a subsequence, as (first, last),
-- or nil. Greedy forward to find where the match can end, then greedy backward
-- from there to find the latest place it can start — so `evenapi` scores
-- against the `eventsApi` at the end of LinkedInEventsApi.kt rather than the
-- `e` back in "Linked".
local function subseq_span(s, p)
  local si, pi, last = 1, 1, nil
  while si <= #s and pi <= #p do
    if s:sub(si, si) == p:sub(pi, pi) then pi = pi + 1; last = si end
    si = si + 1
  end
  if pi <= #p then return nil end

  local sj, pj, first = last, #p, nil
  while sj >= 1 and pj >= 1 do
    if s:sub(sj, sj) == p:sub(pj, pj) then pj = pj - 1; first = sj end
    sj = sj - 1
  end
  return first, last
end

-- Rank a hit against the pattern. A tier for *how* it matched, then how
-- tightly (a contiguous match spans exactly #pattern, a loose subsequence
-- spans more), then the shallower path, then the shorter name. Matched
-- lowercased and literally on purpose — a pattern carrying regex
-- metacharacters was passed to fd verbatim, so it scores at the floor tier and
-- falls through to the depth tie-break, which is still a sane order.
--
-- Kept in step with the awk copy in ~/dotfiles/zshrc.nv, which `f -f` uses:
-- `f -f api` and `nv -f api` must open the same file.
local function score(path, pat)
  local base = path:match("[^/]+$") or path
  local lb, lp = base:lower(), pat:lower()
  local stem = lb:gsub("%.[^.]*$", "")

  local tier, span
  if lb == lp then tier, span = 6, #lp
  elseif stem == lp then tier, span = 5, #lp
  elseif lb:sub(1, #lp) == lp then tier, span = 4, #lp
  elseif lb:find(lp, 1, true) then tier, span = 3, #lp
  else
    local a, b = subseq_span(lb, lp)
    if a then tier, span = 2, b - a + 1 else tier, span = 1, #lb end
  end

  local depth = select(2, path:gsub("/", ""))
  return tier * 1e10
    + (999 - math.min(span, 999)) * 1e6
    + (99  - math.min(depth, 99)) * 1e4
    + (999 - math.min(#base, 999))
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

-- Put `path` on screen as a tab immediately left of the results tab, keeping
-- the results tab last. Unless `focus`, the cursor goes back where it was —
-- tabpage *and* window, since the results tab can be split and landing in the
-- wrong window of the right tab is as disruptive as landing in the wrong tab.
--
-- A path that is already open in some tab counts as done and is left exactly
-- where it is. Note this deliberately does *not* go through
-- tab_utils.focus_if_open, the way telescope and netrw do: that helper jumps
-- to the tab it finds, which is right when a keypress asked for the file and
-- wrong for a background hit — it would be the one way a search result could
-- still yank you out of what you were reading.
--
-- Returns true if the path ended up on screen.
local function open_hit_tab(path, focus)
  local tab, win = tab_utils.find_tab_with_file(path)
  if tab then
    if focus then
      vim.api.nvim_set_current_tabpage(tab)
      if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    end
    return true
  end

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

-- Settle the tabs onto the real top MAX_TABS once the search is over.
--
-- Banding orders hits by *depth*, which is all it can do while results are
-- still arriving: it cannot separate ten files that all sit at depth 8, and a
-- subsequence pattern loose enough to find LinkedInEventsApi.kt from `evenapi`
-- also drags in things that only match by accident. So the tabs that went up
-- during the search are the first five released, not the best five — a rank
-- needs everything, and everything only exists at the end. That is when this
-- runs:
--
--   * hits that outrank an open tab get opened, and the tabs they displace are
--     closed — a tab this command opened seconds ago and you have not looked
--     at is not something to be precious about;
--   * the tab you are *in* is never closed, nor is one whose buffer you have
--     edited (the write would block on E37 anyway), so the set can end up one
--     or two over MAX_TABS. That is the right way to be wrong;
--   * the tabline is then sorted best-first, and if you are still sitting on
--     the tab `nv` dropped you on — you have not paged away, so you were
--     waiting for it — you are moved to the best hit. Having navigated
--     anywhere at all is enough to be left alone.
local function settle_tabs()
  local ranked = vim.deepcopy(state.hits)
  table.sort(ranked, by_rank)

  local want, want_set = {}, {}
  for i = 1, math.min(MAX_TABS, #ranked) do
    want[i] = ranked[i].path
    want_set[ranked[i].path] = true
  end

  local cur = vim.api.nvim_get_current_tabpage()
  local follow = (cur == state.auto_tab)
  local lazy = vim.o.lazyredraw
  vim.o.lazyredraw = true

  -- Drop the tabs that did not survive the ranking.
  for path in pairs(state.opened) do
    if not want_set[path] then
      local tab, win = tab_utils.find_tab_with_file(path)
      if tab and tab ~= cur and not vim.bo[vim.api.nvim_win_get_buf(win)].modified then
        if pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab)) then
          state.opened[path] = nil
        end
      end
    end
  end

  -- Open the ones that earned a tab, and put everything in rank order.
  for i, path in ipairs(want) do
    if not state.opened[path] then
      if open_hit_tab(path, false) then state.opened[path] = true end
    end
    local tab = tab_utils.find_tab_with_file(path)
    if tab and vim.api.nvim_tabpage_get_number(tab) ~= i then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabmove " .. (i - 1))  -- :tabmove N puts this tab after tab N
    end
  end

  local target = cur
  if follow and want[1] then target = tab_utils.find_tab_with_file(want[1]) end
  if target and vim.api.nvim_tabpage_is_valid(target) then
    vim.api.nvim_set_current_tabpage(target)
  end
  vim.o.lazyredraw = lazy
  if follow then state.auto_tab = vim.api.nvim_get_current_tabpage() end
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
        if focus then state.auto_tab = vim.api.nvim_get_current_tabpage() end
      end
    end,
    function(hits, truncated, done)
      M.show(hits, truncated, done)
      if done then settle_tabs(); M.show(hits, truncated, done) end
    end)
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
