-- Sync Windows Terminal background color and title based on nvim's CWD.
-- Writes OSC 11 (bg color) and OSC 2 (title) to /dev/tty, which is nvim's
-- controlling terminal (= the outer Windows Terminal pane). Complements the
-- zsh precmd hook in ~/.zshrc for shell prompts and nvim :terminal buffers.

-- ── background image dimming ──────────────────────────────────────────────────
-- Dims the WT background image while nvim is active; restores on leave.
-- Must match _WT_SHELL_OPACITY in zshrc.visuals.
local WT_SETTINGS = "/mnt/c/Users/HP Pavilion  15-bc07/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"
local WT_PROFILE  = "Debian.01"
local WT_DIM_OPACITY   = 0.08
local WT_SHELL_OPACITY = 0.18

local _set_opacity_py = [[
import sys, json
settings, profile, opacity = sys.argv[1], sys.argv[2], float(sys.argv[3])
d = json.load(open(settings))
for p in d["profiles"]["list"]:
    if p.get("name") == profile:
        p["backgroundImageOpacity"] = opacity
        break
open(settings, "w").write(json.dumps(d, indent=4))
]]

local function set_bg_opacity(opacity)
  vim.fn.system({ "python3", "-c", _set_opacity_py, WT_SETTINGS, WT_PROFILE, tostring(opacity) })
end

vim.api.nvim_create_autocmd("VimEnter", {
  callback = function() vim.schedule(function() set_bg_opacity(WT_DIM_OPACITY) end) end,
})
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function() set_bg_opacity(WT_SHELL_OPACITY) end,
})
-- ─────────────────────────────────────────────────────────────────────────────

-- ── color config ─────────────────────────────────────────────────────────────
local COLORS = {
  default  = "#262A30",  -- matches "Color Scheme 10" background
  backend  = "#252E28",  -- soft green tint
  frontend = "#23293A",  -- soft blue tint
}
-- ─────────────────────────────────────────────────────────────────────────────

local function write_osc(seq)
  local tty = io.open("/dev/tty", "w")
  if tty then
    tty:write(seq)
    tty:close()
  end
end

local function short_dir(cwd)
  local home = vim.loop.os_homedir()
  if cwd == home then return "~" end
  return vim.fn.fnamemodify(cwd, ":t")  -- last path component
end

local function update_title()
  local cwd = vim.fn.getcwd()
  local bufname = vim.api.nvim_buf_get_name(0)
  local ft = vim.bo.filetype
  local label

  if ft == "netrw" or (bufname ~= "" and vim.fn.isdirectory(bufname) == 1) then
    -- netrw or directory buffer: show directory name
    local dir = bufname ~= "" and bufname or cwd
    label = vim.fn.fnamemodify(dir, ":t")
    if label == "" then label = "~" end
  elseif bufname ~= "" then
    -- normal file: show filename
    label = vim.fn.fnamemodify(bufname, ":t")
  else
    -- no file open: show cwd
    label = short_dir(cwd)
  end

  write_osc("\027]2;nvim - " .. label .. "\007")
end

local function update()
  local cwd = vim.fn.getcwd()

  -- background color
  local bg
  if cwd:find("backend", 1, true) then
    bg = COLORS.backend
  elseif cwd:find("frontend", 1, true) or cwd:find("ui", 1, true) then
    bg = COLORS.frontend
  else
    bg = COLORS.default
  end
  write_osc("\027]11;" .. bg .. "\007")

  update_title()
end

vim.api.nvim_create_autocmd({ "DirChanged", "VimEnter" }, {
  callback = function() vim.schedule(update) end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  callback = function() vim.schedule(update_title) end,
})

vim.api.nvim_create_autocmd("VimLeave", {
  callback = function()
    write_osc("\027]11;" .. COLORS.default .. "\007")
    -- reset title to just cwd so zsh precmd takes over cleanly
    local dir = short_dir(vim.fn.getcwd())
    write_osc("\027]2;" .. dir .. "\007")
  end,
})
