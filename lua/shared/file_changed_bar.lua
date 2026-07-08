local warn_win, warn_buf

local function show_bar()
  if warn_win and vim.api.nvim_win_is_valid(warn_win) then return end
  warn_buf = vim.api.nvim_create_buf(false, true)

  local label = "  ⚠  FILE CHANGED ON DISK — :e! to reload (this discards unsaved changes)  "
  local pad = string.rep(" ", math.max(0, vim.o.columns - #label))
  vim.api.nvim_buf_set_lines(warn_buf, 0, -1, false, { label .. pad })

  warn_win = vim.api.nvim_open_win(warn_buf, false, {
    relative  = "editor",
    row       = vim.o.lines - 3,
    col       = 0,
    width     = vim.o.columns,
    height    = 1,
    style     = "minimal",
    focusable = false,
    zindex    = 200,
  })
  vim.api.nvim_win_set_option(warn_win, "winhl", "Normal:WarningMsg")
end

local function hide_bar()
  if warn_win and vim.api.nvim_win_is_valid(warn_win) then
    vim.api.nvim_win_close(warn_win, true)
  end
  if warn_buf and vim.api.nvim_buf_is_valid(warn_buf) then
    vim.api.nvim_buf_delete(warn_buf, { force = true })
  end
  warn_win, warn_buf = nil, nil
end

local g = vim.api.nvim_create_augroup("FileChangedBar", { clear = true })

-- Fires when :checktime finds the file on disk differs from the buffer.
-- We take over the notification ourselves (fcs_choice = "") so vim doesn't
-- also print its own W11/W12 message or silently reload with 'autoread'.
vim.api.nvim_create_autocmd("FileChangedShell", {
  group = g,
  callback = function()
    vim.v.fcs_choice = ""
    show_bar()
  end,
})

-- Reloading (:e!) or saving brings the buffer back in sync with disk.
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = g,
  callback = hide_bar,
})

-- 'checktime' only compares mtimes on these events, it doesn't poll — so we
-- trigger it ourselves on the events most likely to catch an external change.
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  group = g,
  callback = function()
    if vim.bo.buftype == "" then
      vim.cmd("silent! checktime")
    end
  end,
})
