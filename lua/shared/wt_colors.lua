-- Sync Windows Terminal background color based on nvim's current working directory.
-- Writes OSC 11 escape sequences to /dev/tty, which is nvim's controlling terminal
-- (= the outer Windows Terminal pane). Complements the zsh precmd hook in ~/.zshrc,
-- which handles the same for shell prompts (including inside nvim :terminal).

local DEFAULT_BG = "#262A30"  -- matches "Color Scheme 10" background

local function write_osc(color)
  local tty = io.open("/dev/tty", "w")
  if tty then
    tty:write("\027]11;" .. color .. "\007")
    tty:close()
  end
end

local function update()
  local cwd = vim.fn.getcwd()
  if cwd:find("backend", 1, true) then
    write_osc("#2B1A09")                           -- calm orange
  elseif cwd:find("frontend", 1, true) or cwd:find("ui", 1, true) then
    write_osc("#091828")                           -- calm blue
  else
    write_osc(DEFAULT_BG)
  end
end

vim.api.nvim_create_autocmd({ "DirChanged", "VimEnter" }, {
  callback = function() vim.schedule(update) end,
})

-- restore default when leaving nvim
vim.api.nvim_create_autocmd("VimLeave", {
  callback = function() write_osc(DEFAULT_BG) end,
})
