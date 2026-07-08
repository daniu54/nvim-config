-- Shared helpers for "focus existing tab instead of opening a duplicate" behavior.
-- Used by telescope (C-o, leader-fg) and netrw (\ background-tab open).
local M = {}

-- Returns tabpage/window handles if `path` is already open in some tab, else nil.
function M.find_tab_with_file(path)
  local target = vim.fn.fnamemodify(path, ':p')
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      local bname = vim.api.nvim_buf_get_name(buf)
      if bname ~= '' and vim.fn.fnamemodify(bname, ':p') == target then
        return tab, win
      end
    end
  end
  return nil
end

-- If `path` is already open in some tab, focuses that tab/window and returns true.
function M.focus_if_open(path)
  local tab, win = M.find_tab_with_file(path)
  if tab then
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_set_current_win(win)
    return true
  end
  return false
end

return M
