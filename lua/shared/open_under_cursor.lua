-- Make paths and URLs in any buffer "clickable" with <CR> in normal mode.
--
-- One resolver, three consumers: <CR> (this file's map), `gx` and `<leader>gf`
-- in remap.lua. Everything WSL-specific lives here:
--   url          -> ~/bin/open-url (Firefox on the Windows side)
--   text file    -> nvim, in a tab (focus the tab it is already open in)
--   directory    -> netrw, in a tab
--   binary file  -> explorer.exe /select, so the folder opens with it selected
--
-- Terminal buffers are covered for free: a global normal-mode map applies in a
-- terminal buffer's normal mode too. The only extra work there is resolving
-- relative paths against the *shell's* cwd (/proc/<job pid>/cwd), not nvim's --
-- output scrolling past in a shell that has cd'd elsewhere is the main reason
-- this exists at all.

local tab_utils = require("shared.tab_utils")

local M = {}

-- Characters a bare path/url token may contain. Includes `\` and `:` for
-- Windows paths (D:\foo) and for the :line:col suffix, both stripped below.
local TOKEN = "[%w%._%-~%$@%+/\\:#%%]"

local URL_PAT = "%a[%w%+%-%.]*://[%w%.%-%_~:/?#%[%]@!$&'%(%)%*%+,;=%%]+"

-- Extensions that are never worth opening in nvim even though some of them are
-- technically text (svg, drawio): the OS handler is what you want.
local OPENABLE = {
  pdf = true, png = true, jpg = true, jpeg = true, gif = true, bmp = true,
  webp = true, ico = true, svg = true, tif = true, tiff = true, psd = true,
  mp3 = true, mp4 = true, mkv = true, avi = true, mov = true, wav = true,
  flac = true, webm = true, ogg = true,
  zip = true, tar = true, gz = true, xz = true, bz2 = true, ["7z"] = true,
  rar = true, jar = true, exe = true, dll = true, msi = true, so = true,
  doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true,
  odt = true, ods = true, odp = true, epub = true, mobi = true,
  ttf = true, otf = true, woff = true, woff2 = true, drawio = true,
  excalidraw = false, -- json, and this config edits them
}

local function shell(cmd)
  local out = vim.fn.system(cmd)
  return (out:gsub("%s+$", ""))
end

---------------------------------------------------------------------------
-- detection
---------------------------------------------------------------------------

-- The token under `col` (0-indexed) in `line`, preferring a quoted/bracketed
-- span so that paths containing spaces still work.
local function span_at(line, col)
  -- quoted or markdown-link spans first: "a b.txt", 'a b.txt', `a b.txt`, (a b.txt)
  for _, pair in ipairs({ { '"', '"' }, { "'", "'" }, { "`", "`" }, { "(", ")" }, { "<", ">" } }) do
    local open, close = pair[1], pair[2]
    local s = 1
    while true do
      local a = line:find(open, s, true)
      if not a then break end
      local b = line:find(close, a + 1, true)
      if not b then break end
      if a <= col and col < b - 1 and b - a > 1 then
        local inner = line:sub(a + 1, b - 1)
        -- only take it if it looks like a path/url, not arbitrary prose
        if inner:match("^%S") and (inner:find("[/\\]") or inner:find("://")) then
          return inner
        end
      end
      s = a + 1
    end
  end

  local s = 1
  while true do
    local ms, me = line:find(TOKEN .. "+", s)
    if not ms then return nil end
    if ms - 1 <= col and col <= me - 1 then
      return line:sub(ms, me)
    end
    s = me + 1
  end
end

-- Returns a target table, or nil.
--   { kind = "url",  url = "..." }
--   { kind = "path", path = "<absolute>", lnum = n?, col = n? }
function M.detect(line, col)
  -- a URL wins over a path: it contains slashes and would parse as one
  local s = 1
  while true do
    local ms, me = line:find(URL_PAT, s)
    if not ms then break end
    if ms - 1 <= col and col <= me - 1 then
      local url = line:sub(ms, me)
      -- trailing punctuation and an unbalanced `)` from [text](url)
      url = url:gsub("[%.,;:!%?'\"]+$", "")
      if url:sub(-1) == ")" and not url:find("%(") then url = url:sub(1, -2) end
      return { kind = "url", url = url }
    end
    s = me + 1
  end

  local token = span_at(line, col)
  if not token then return nil end

  -- www.foo.com with no scheme
  if token:match("^www%.[%w%-]+%.%a") then
    return { kind = "url", url = "https://" .. token:gsub("[%.,;:!%?]+$", "") }
  end

  token = token:gsub("^[%(%[<'\"`]+", ""):gsub("[%)%]>'\"`]+$", "")
  token = token:gsub("[%.,;:!%?]+$", "")

  local lnum, cnum
  -- path:12:5 / path:12  (but not D:\foo -- a single letter before `:` is a drive)
  local base, l, c = token:match("^(.-):(%d+):(%d+)$")
  if base then
    token, lnum, cnum = base, tonumber(l), tonumber(c)
  else
    base, l = token:match("^(.-):(%d+)$")
    if base then token, lnum = base, tonumber(l) end
  end

  if token == "" then return nil end

  local path = M.resolve(token)
  if not path then return nil end
  return { kind = "path", path = path, lnum = lnum, col = cnum }
end

---------------------------------------------------------------------------
-- resolution
---------------------------------------------------------------------------

local function exists(p)
  return vim.fn.filereadable(p) == 1 or vim.fn.isdirectory(p) == 1
end

-- Walk down from `pid` while there is exactly one child, and return that
-- process's cwd. The pane may be running something under the shell (an inner
-- nvim), and it is the innermost one whose cwd you are looking at.
local function proc_cwd(pid)
  local cur = tostring(pid)
  for _ = 1, 6 do
    local kids = shell({ "bash", "-c", "cat /proc/" .. cur .. "/task/*/children 2>/dev/null" })
    local list = vim.split(kids, "%s+", { trimempty = true })
    if #list ~= 1 then break end
    cur = list[1]
  end
  return vim.uv.fs_readlink("/proc/" .. cur .. "/cwd")
end

-- The cwd of the tmux pane displayed in the terminal whose job is `root_pid`.
--
-- This is the case that matters here: an nvim :terminal in this config runs
-- `tmux attach-session`, and a tmux pane's shell is a child of the tmux
-- *server*, not of the client nvim spawned. So /proc/<job pid>/cwd is nvim's
-- own cwd and the pane's shell is nowhere in that process tree at all -- the
-- only way across the gap is to ask tmux. Matching on client pid rather than on
-- this config's `nvt-<pid>-<n>` session names keeps it working for any tmux.
--
-- tmux is asked for the pane's **pid**, and the cwd is then read from /proc:
-- `#{pane_current_path}` is cached and only refreshed while a client is
-- redrawing, so it can lag a `cd` by an arbitrary amount. It is kept as a
-- fallback for when /proc cannot be read.
local function tmux_pane_cwd(root_pid)
  if vim.fn.executable("tmux") ~= 1 then return nil end
  local out = shell({ "tmux", "list-clients", "-F", "#{client_pid}\t#{pane_pid}\t#{pane_current_path}" })
  if vim.v.shell_error ~= 0 or out == "" then return nil end

  local by_pid = {}
  for line in out:gmatch("[^\n]+") do
    local cpid, ppid, path = line:match("^(%d+)\t(%d+)\t(.*)$")
    if cpid then by_pid[cpid] = { pane = ppid, path = path } end
  end

  -- the client may be the job itself or a descendant of it (a wrapper script,
  -- a shell that exec'd tmux), so walk down
  local queue, seen = { tostring(root_pid) }, {}
  for _ = 1, 64 do
    local cur = table.remove(queue, 1)
    if not cur then break end
    local client = by_pid[cur]
    if client then
      local cwd = proc_cwd(client.pane)
      if cwd then return cwd end
      return client.path ~= "" and client.path or nil
    end
    if not seen[cur] then
      seen[cur] = true
      local kids = shell({ "bash", "-c", "cat /proc/" .. cur .. "/task/*/children 2>/dev/null" })
      for k in kids:gmatch("%d+") do table.insert(queue, k) end
    end
  end
  return nil
end

-- The cwd a relative path in this buffer should be read against. In a terminal
-- that is the shell's own cwd, which is usually not nvim's.
--
-- A scratch buffer showing a terminal's output -- the <C-e> tmux scrollback in
-- after/plugin/telescope.lua -- is full of the same relative paths but is a
-- `nofile` buffer with no job of its own, so it can point at the terminal it
-- came from with `b:open_under_cursor_term_buf` and borrow its cwd. That is a
-- buffer *number*, not a path, deliberately: it is resolved on every <CR>, so
-- a `cd` in the pane after the scrollback was captured is still followed.
-- `b:open_under_cursor_cwd` is the blunt version for anything that just knows
-- its directory.
function M.buffer_cwd(buf)
  buf = buf or 0

  local fixed = vim.b[buf].open_under_cursor_cwd
  if type(fixed) == "string" and fixed ~= "" then return fixed end

  local origin = vim.b[buf].open_under_cursor_term_buf
  if type(origin) == "number" and origin ~= buf
    and vim.api.nvim_buf_is_valid(origin)
    and vim.bo[origin].buftype == "terminal" then
    local cwd = M.buffer_cwd(origin)
    if cwd then return cwd end
  end

  if vim.bo[buf].buftype == "terminal" then
    local pid = vim.b[buf].terminal_job_pid
    if pid then
      local cwd = tmux_pane_cwd(pid) or proc_cwd(pid)
      if cwd then return cwd end
    end
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" and vim.bo[buf].buftype == "" then
    return vim.fn.fnamemodify(name, ":h")
  end

  -- Last resort before nvim's own cwd: the cwd of the shell nvim was launched
  -- from. For a plain file buffer the two are the same, so this only shows up
  -- in a scratch/[No Name] buffer after a `:cd` has moved nvim away from where
  -- you started it -- there, the directory you typed the path in is the better
  -- guess. Deliberately *not* used for the <C-e> scrollback: that is a
  -- different terminal (see open_under_cursor_term_buf above).
  local ppid = vim.uv.os_getppid and vim.uv.os_getppid()
  if ppid then
    local launched_in = vim.uv.fs_readlink("/proc/" .. ppid .. "/cwd")
    if launched_in and launched_in ~= "/" then return launched_in end
  end

  return vim.fn.getcwd()
end

-- token -> absolute existing path, or nil
function M.resolve(token)
  -- file:// URL
  local file_url = token:match("^file://(.*)$")
  if file_url then
    token = vim.uri_decode(file_url)
    if token:match("^/%a:/") then token = token:sub(2) end -- file:///C:/...
  end

  -- Windows path (D:\foo or D:/foo) -> WSL
  if token:match("^%a:[/\\]") then
    local wsl = shell({ "wslpath", "-u", (token:gsub("\\", "/")) })
    if wsl ~= "" and exists(wsl) then return wsl end
    return nil
  end
  if token:find("\\") and not token:find("/") then
    token = token:gsub("\\", "/")
  end

  token = vim.fn.expand(token:gsub("^~", "~")) -- ~ and $VARs

  if token:sub(1, 1) == "/" then
    return exists(token) and token or nil
  end

  local cwd = M.buffer_cwd()
  local candidates = {}
  if cwd then table.insert(candidates, cwd .. "/" .. token) end
  table.insert(candidates, vim.fn.getcwd() .. "/" .. token)
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then table.insert(candidates, vim.fn.fnamemodify(name, ":h") .. "/" .. token) end

  for _, c in ipairs(candidates) do
    if exists(c) then return (vim.fn.fnamemodify(c, ":p"):gsub("/$", "")) end
  end
  return nil
end

---------------------------------------------------------------------------
-- opening
---------------------------------------------------------------------------

-- Does this file belong in nvim? Extension first (so a 2 GB mkv is never read),
-- then a NUL sniff of the first KiB for everything else.
local function is_text(path)
  local ext = path:match("%.([%w]+)$")
  if ext and OPENABLE[ext:lower()] then return false end
  local fd = io.open(path, "rb")
  if not fd then return true end
  local chunk = fd:read(1024) or ""
  fd:close()
  return not chunk:find("\0", 1, true)
end

local function open_in_explorer(path)
  local win = shell({ "wslpath", "-w", path })
  if win == "" then
    vim.notify("wslpath failed for " .. path, vim.log.levels.ERROR)
    return
  end
  if vim.fn.isdirectory(path) == 1 then
    vim.fn.jobstart({ "explorer.exe", win }, { detach = true })
  else
    vim.fn.jobstart({ "explorer.exe", "/select," .. win }, { detach = true })
  end
  vim.notify("Explorer: " .. path)
end

function M.open(target)
  if target.kind == "url" then
    vim.fn.jobstart({ vim.fn.expand("~/bin/open-url"), target.url }, { detach = true })
    vim.notify("Firefox: " .. target.url)
    return true
  end

  local path = target.path
  local isdir = vim.fn.isdirectory(path) == 1

  if not isdir and not is_text(path) then
    open_in_explorer(path)
    return true
  end

  if tab_utils.focus_if_open(path) then
    if target.lnum then
      vim.api.nvim_win_set_cursor(0, { target.lnum, (target.col or 1) - 1 })
      vim.cmd("normal! zz")
    end
    return true
  end

  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  if target.lnum and not isdir then
    pcall(vim.api.nvim_win_set_cursor, 0, { target.lnum, (target.col or 1) - 1 })
    vim.cmd("normal! zz")
  end
  return true
end

-- opts: { url_only = bool, silent = bool }
-- Returns true if something was opened.
function M.open_under_cursor(opts)
  opts = opts or {}
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".") - 1
  local target = M.detect(line, col)

  if target and opts.url_only and target.kind ~= "url" then target = nil end

  if not target then
    if not opts.silent then
      vim.notify(opts.url_only and "No URL under cursor" or "No path or URL under cursor",
        vim.log.levels.WARN)
    end
    return false
  end
  return M.open(target)
end

return M
