vim.g.mapleader = " "
vim.g.maplocalleader = ' '

-- open project view
vim.keymap.set("n", "<leader>pv", function() vim.cmd("Texplore") end)

-- move selection up and down while preserving indentation
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- j appends line to previous, this makes the cursor stay in place
vim.keymap.set("n", "J", "mzJ`z")

-- keep cursor in middle when jumping
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")

-- fast up down
vim.keymap.set({"n", "v"}, "<BS>", "<C-d>")
vim.keymap.set({"n", "v"}, "<leader><BS>", "<C-u>")

-- keep cursor in middle when searching
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- paste without overwriting buffer
vim.keymap.set("x", "<leader>p", [["_dP]])

-- delete without overwriting buffer
vim.keymap.set({"n", "v"}, "<leader>D", [["_d]])

-- yank into system clipboard
vim.keymap.set({"n", "v"}, "<leader>Y", [["+y]])

-- paste from system clipboard
vim.keymap.set({"n", "v"}, "<leader>P", [["+p]])

-- quick search-replace word under cursor
vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]])

-- netrw keymaps
vim.api.nvim_create_autocmd("FileType", {
  pattern = "netrw",
  callback = function()
    -- yp: copy full path of file under cursor to Windows clipboard
    vim.keymap.set("n", "yp", function()
      local path = vim.fn.expand("<cfile>:p")
      vim.fn.system("clip.exe", path)
      vim.notify("Copied: " .. path)
    end, { buffer = true })

    -- !: run a shell command on the file under cursor.
    -- % in the command is replaced with the full path of the cursor file.
    -- Example: `cat %`  →  :!cat '/path/to/file'
    vim.keymap.set("n", "!", function()
      local file = vim.fn.expand("<cfile>:p")
      local cmd = vim.fn.input(":! ", "", "shellcmd")
      if cmd == "" then return end
      local expanded = cmd:gsub("%%", vim.fn.shellescape(file))
      vim.cmd("!" .. expanded)
    end, { buffer = true, desc = "Run shell command; % = file under cursor" })

    -- o: open file in current window (overrides netrw default hsplit).
    -- Toggles netrw_browse_split=0 around a synthetic <CR>, then restores it
    -- to 3 (the default we set in set.lua).
    vim.keymap.set("n", "o", function()
      vim.g.netrw_browse_split = 0
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "m", false)
      vim.schedule(function() vim.g.netrw_browse_split = 3 end)
    end, { buffer = true, desc = "netrw: open in current window" })

    -- \: open file in background tab (new tab, stay focused on netrw).
    vim.keymap.set("n", "\\", function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("t", true, false, true), "m", false)
      vim.schedule(function() vim.cmd("tabprev") end)
    end, { buffer = true, desc = "netrw: open in background tab" })
  end,
})

-- open URL under cursor in Firefox (WSL → Windows via PowerShell)
vim.keymap.set("n", "gx", function()
  local line = vim.fn.getline(".")
  local col = vim.fn.col(".") - 1  -- 0-indexed
  local url_pat = "https?://[%w%.%-%_~:/?#%[%]@!$&'%(%)%*%+,;=%%]+"
  local s = 1
  while true do
    local ms, me = line:find(url_pat, s)
    if not ms then break end
    if ms - 1 <= col and col <= me - 1 then
      vim.fn.jobstart({ vim.fn.expand("~/bin/open-url"), line:sub(ms, me) })
      return
    end
    s = me + 1
  end
  vim.notify("No URL under cursor", vim.log.levels.WARN)
end, { desc = "Open URL under cursor" })

-- open path under cursor in a new nvim window (WSL → Windows Terminal)
vim.keymap.set("n", "<leader>gf", function()
  local line = vim.fn.getline(".")
  local col = vim.fn.col(".") - 1  -- 0-indexed

  -- Find path-like token at cursor position (stops at parens, quotes, spaces)
  local path_pat = "[%w_%.%/%-][%w_%.%/%-]*"
  local s = 1
  local token = nil
  while true do
    local ms, me = line:find(path_pat, s)
    if not ms then break end
    if ms - 1 <= col and col <= me - 1 then
      token = line:sub(ms, me)
      break
    end
    s = me + 1
  end

  if not token then
    vim.notify("No path under cursor", vim.log.levels.WARN)
    return
  end

  -- Strip trailing :line_number and punctuation
  token = token:gsub(":%d+.*$", ""):gsub("[%.%,%;]+$", "")

  local function exists(p) return vim.fn.filereadable(p) == 1 or vim.fn.isdirectory(p) == 1 end

  local function open_resolved(resolved)
    local dir = vim.fn.fnamemodify(resolved, ":h")
    local win_dir = vim.fn.system("wslpath -w " .. vim.fn.shellescape(dir)):gsub("\n$", "")
    vim.fn.jobstart({ "wt.exe", "-d", win_dir, "wsl.exe", "nvim", resolved })
  end

  local resolved = nil

  if token:sub(1, 2) == "./" or token:sub(1, 1) ~= "/" then
    -- relative: try cwd/token (stripping leading ./ if present)
    local clean = token:gsub("^%./", "")
    local candidate = vim.fn.getcwd() .. "/" .. clean
    if exists(candidate) then resolved = vim.fn.fnamemodify(candidate, ":p") end
  end

  if not resolved and token:sub(1, 1) == "/" then
    -- absolute
    if exists(token) then resolved = token end
  end

  if not resolved then
    vim.notify("Path not found: " .. token, vim.log.levels.WARN)
    return
  end

  open_resolved(resolved)
end, { desc = "Open path under cursor in new window" })

-- yp: copy full path of current file to Windows clipboard (mirrors netrw yp)
vim.keymap.set("n", "yp", function()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("No file", vim.log.levels.WARN)
    return
  end
  vim.fn.system("clip.exe", path)
  vim.notify("Copied: " .. path)
end, { desc = "Copy current file path to clipboard" })

-- !: run a shell command; % is replaced with the current file's full path.
-- Mirrors the netrw "!" mapping for regular file buffers.
vim.keymap.set("n", "!", function()
  local file = vim.fn.expand("%:p")
  local cmd = vim.fn.input(":! ", "", "shellcmd")
  if cmd == "" then return end
  local expanded = cmd:gsub("%%", vim.fn.shellescape(file))
  vim.cmd("!" .. expanded)
end, { desc = "Run shell command; % = current file" })

-- open visual selection in Firefox (<leader>i)
vim.keymap.set("v", "<leader>i", function()
  local saved = vim.fn.getreg('z')
  local saved_type = vim.fn.getregtype('z')
  vim.cmd('normal! "zy')
  local raw = vim.fn.getreg('z')
  vim.fn.setreg('z', saved, saved_type)

  -- collapse newlines and trim
  local text = raw:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$")
  if text == "" then return end

  vim.fn.jobstart({ vim.fn.expand("~/bin/open-url"), text })
end, { desc = "Open selection in Firefox" })

-- fold helpers
-- zL/zl override scroll-right (zL = half screen, zl = 1 char) — unused with wrap on
-- Both accept: Enter → level 1, number → fold level, string → fuzzy term search
-- Both toggle: running the same command twice opens what was just folded

local function set_foldlevel_range(start_l, end_l, level)
  local saved = vim.fn.getcurpos()
  local i = start_l
  while i <= end_l do
    if vim.fn.foldlevel(i) > level and vim.fn.foldclosed(i) == -1 then
      vim.fn.cursor(i, 1)
      pcall(vim.cmd, "normal! zc")
    end
    local fe = vim.fn.foldclosedend(i)
    i = (fe > 0) and (fe + 1) or (i + 1)
  end
  i = start_l
  while i <= end_l do
    local fl = vim.fn.foldlevel(i)
    if fl > 0 and fl <= level and vim.fn.foldclosed(i) ~= -1 then
      vim.fn.cursor(i, 1)
      pcall(vim.cmd, "normal! zo")
    end
    i = i + 1
  end
  vim.fn.setpos(".", saved)
end

-- True fold-start detection via treesitter foldexpr (returns ">N" for fold headers).
-- fl > prev_fl fails for sibling folds at the same level, hence direct query.
local function is_fold_start(lnum)
  local ok, res = pcall(function()
    vim.v.lnum = lnum
    return vim.treesitter.foldexpr()
  end)
  if ok and type(res) == "string" then return res:sub(1, 1) == ">" end
  return vim.fn.foldlevel(lnum) > ((lnum > 1) and vim.fn.foldlevel(lnum - 1) or 0)
end

-- Extent of the fold whose header is at header_line.
-- Stops at sibling (same level + is_fold_start) or foldlevel drop.
local function get_fold_extent(header_line)
  local fl    = vim.fn.foldlevel(header_line)
  local total = vim.fn.line("$")
  local el    = header_line
  for i = header_line + 1, total do
    local ifl = vim.fn.foldlevel(i)
    if ifl < fl then break end
    if ifl == fl and is_fold_start(i) then break end
    el = i
  end
  return header_line, el
end

-- Walk backward from cursor to find the nearest fold-start line.
local function find_enclosing_header(cursor_line)
  for i = cursor_line, 1, -1 do
    if is_fold_start(i) then return i end
  end
  return cursor_line
end

-- True if any fold at level > threshold is already closed within [start_l, end_l].
local function range_has_closed_folds_deeper_than(start_l, end_l, threshold)
  for i = start_l, end_l do
    if vim.fn.foldlevel(i) > threshold and vim.fn.foldclosed(i) ~= -1 then
      return true
    end
  end
  return false
end

local function set_foldlevel_local(level)
  local cur = vim.fn.line(".")
  if vim.fn.foldlevel(cur) == 0 then return end
  local header   = find_enclosing_header(cur)
  local _, end_l = get_fold_extent(header)
  local target   = range_has_closed_folds_deeper_than(header, end_l, level) and 99 or level
  set_foldlevel_range(header, end_l, target)
end

-- fuzzy-smart match: exact > prefix > substring > char-order fuzzy
local function fold_term_score(pat, word)
  local p, w = pat:lower(), word:lower()
  if w == p              then return 4 end
  if w:sub(1, #p) == p  then return 3 end
  if w:find(p, 1, true) then return 2 end
  local pi = 1
  for si = 1, #w do
    if w:sub(si, si) == p:sub(pi, pi) then
      pi = pi + 1
      if pi > #p then return 1 end
    end
  end
  return 0
end

-- Search for the best matching fold header within [start_l, end_l].
local function find_fold_by_term(term, start_l, end_l)
  start_l = start_l or 1
  end_l   = end_l   or vim.fn.line("$")
  local best_line, best_score = nil, 0
  for i = start_l, end_l do
    if is_fold_start(i) then
      local word  = vim.fn.getline(i):match("^%s*([^:%s]+)") or ""
      local score = fold_term_score(term, word)
      if score > best_score then best_score = score; best_line = i end
    end
  end
  return best_line
end

local function smart_fold(input, is_global)
  local s     = input:match("^%s*(.-)%s*$")
  local level = tonumber(s)

  if s == "" or level then
    local n = level or 1
    if is_global then
      local target = (vim.wo.foldlevel == n) and 99 or n
      vim.wo.foldlevel = target
    else
      set_foldlevel_local(n)
    end
    return
  end

  -- term mode: local searches only within the cursor's enclosing fold subtree
  local cur = vim.fn.line(".")
  local search_sl, search_el
  if not is_global and vim.fn.foldlevel(cur) > 0 then
    local ctx_header         = find_enclosing_header(cur)
    search_sl, search_el     = get_fold_extent(ctx_header)
  else
    search_sl, search_el = 1, vim.fn.line("$")
  end

  local tl = find_fold_by_term(s, search_sl, search_el)
  if not tl then
    vim.notify("No fold matching: " .. s, vim.log.levels.WARN)
    return
  end
  local _, fe = get_fold_extent(tl)
  local fl    = vim.fn.foldlevel(tl)
  local label = vim.fn.getline(tl):match("^%s*(.-)%s*$")
  local already = range_has_closed_folds_deeper_than(tl, fe, fl)

  if is_global then
    local target = already and 99 or fl
    vim.wo.foldlevel = target
    vim.notify((already and "unfolded" or "foldlevel=" .. fl) .. "  (" .. label .. ")")
  else
    local target = already and 99 or fl
    set_foldlevel_range(tl, fe, target)
    vim.notify((already and "unfolded" or "folded") .. ": " .. label)
  end
end

vim.keymap.set("n", "zL", function()
  local ok, input = pcall(vim.fn.input, "zL: ")
  if not ok then return end
  smart_fold(input, true)
end, { desc = "Fold global: level N, term, or Enter=1" })

vim.keymap.set("n", "zl", function()
  local ok, input = pcall(vim.fn.input, "zl: ")
  if not ok then return end
  smart_fold(input, false)
end, { desc = "Fold local: level N, term, or Enter=1" })

-- Squirrel (.nut) uses C-style line comments; no treesitter grammar available
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    pattern = "*.nut",
    callback = function() vim.bo.commentstring = "// %s" end,
})

-- close current split
vim.keymap.set("n", "<C-w>x", "<C-w>c", { desc = "Close current split" })

-- swap current split with the other
vim.keymap.set("n", "<C-w>e", function() vim.cmd("wincmd x") end, { desc = "Swap splits" })

-- navigate back and forwards
vim.keymap.set({"n"}, "H", ":bp<CR>", { desc = "Move to previous buffer" })
vim.keymap.set({"n"}, "L", ":bn<CR>", { desc = "Move to next buffer" })

-- Smart search: letters/digits only → literal (\V), else regex.
-- Case is handled by ignorecase+smartcase in set.lua.
-- If the user manually prefixes \v/\V/\c/\C, we leave it alone.
do
  local _last_search = ''
  vim.api.nvim_create_autocmd('CmdlineChanged', {
    pattern = { '/', '?' },
    callback = function() _last_search = vim.fn.getcmdline() end,
  })
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    pattern = { '/', '?' },
    callback = function()
      local term = _last_search
      _last_search = ''
      if term == '' then return end
      if term:match('^\\[vVcC]') then return end  -- user set mode explicitly
      if not term:match('[^a-zA-Z0-9]') then
        -- letters/digits only: force literal, explicit case flag (smartcase won't apply to setreg)
        local case_flag = term:match('[A-Z]') and '\\C' or '\\c'
        vim.fn.setreg('/', case_flag .. '\\V' .. term)
      end
      -- else: regex search — ignorecase+smartcase already applied by nvim
    end,
  })
end
