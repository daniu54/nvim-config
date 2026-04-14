local warn_win, warn_buf

local function show_unsaved_bar()
  if warn_win and vim.api.nvim_win_is_valid(warn_win) then return end
  warn_buf = vim.api.nvim_create_buf(false, true)

  local label = "  ⚠  UNSAVED CHANGES — remember to :w  "
  local pad = string.rep(" ", math.max(0, vim.o.columns - #label))
  vim.api.nvim_buf_set_lines(warn_buf, 0, -1, false, { label .. pad })

  warn_win = vim.api.nvim_open_win(warn_buf, false, {
    relative  = "editor",
    row       = vim.o.lines - 2,
    col       = 0,
    width     = vim.o.columns,
    height    = 1,
    style     = "minimal",
    focusable = false,
    zindex    = 200,
  })
  vim.api.nvim_win_set_option(warn_win, "winhl", "Normal:ErrorMsg")
end

local function hide_unsaved_bar()
  if warn_win and vim.api.nvim_win_is_valid(warn_win) then
    vim.api.nvim_win_close(warn_win, true)
  end
  if warn_buf and vim.api.nvim_buf_is_valid(warn_buf) then
    vim.api.nvim_buf_delete(warn_buf, { force = true })
  end
  warn_win, warn_buf = nil, nil
end

local g = vim.api.nvim_create_augroup("UnsavedBar", { clear = true })

vim.api.nvim_create_autocmd({ "FocusLost", "BufLeave", "WinLeave" }, {
  group = g,
  callback = function()
    if vim.bo.modified then show_unsaved_bar() end
  end,
})

vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "BufWritePost" }, {
  group = g,
  callback = hide_unsaved_bar,
})
