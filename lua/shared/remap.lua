vim.g.mapleader = " "
vim.g.maplocalleader = ' '

-- open project view
vim.keymap.set("n", "<leader>pv", function() vim.cmd("Ex") end)

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
