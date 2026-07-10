-- line_endings.lua — fix Windows line endings (^M / \r) in the current buffer
--
-- :FixLineEndings strips trailing \r from every line and sets fileformat=unix,
-- so the file is saved back out with LF-only endings.

local function fix_line_endings()
  local view = vim.fn.winsaveview()
  vim.cmd([[%s/\r$//e]])
  vim.bo.fileformat = "unix"
  vim.fn.winrestview(view)
  print("Fixed line endings (fileformat=unix)")
end

vim.api.nvim_create_user_command("FixLineEndings", fix_line_endings, {
  desc = "Strip ^M (\\r) and set fileformat=unix for the current buffer",
})
