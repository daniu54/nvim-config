-- cheatsheet.lua — floating window with custom keybindings
-- open with :Cheatsheet or <leader>?

local lines = {
  "  Custom Keybindings                                        ",
  " ─────────────────────────────────────────────────────────── ",
  "  NAVIGATION                                                 ",
  "   H / L            prev / next buffer                       ",
  "   <BS>             scroll ½ page down (like C-d)            ",
  "   <leader><BS>     scroll ½ page up   (like C-u)            ",
  "   <C-d> / <C-u>   scroll ½ page, cursor stays centred      ",
  "   n / N            next / prev search result (centred)      ",
  " ─────────────────────────────────────────────────────────── ",
  "  FILES & BUFFERS                                            ",
  "   <leader>pv       open file explorer (netrw)               ",
  "   gx               open URL under cursor in browser         ",
  "   <leader>gf       open path under cursor in new nvim win   ",
  "   yp  (netrw)      copy file path to Windows clipboard      ",
  " ─────────────────────────────────────────────────────────── ",
  "  TELESCOPE                                                  ",
  "   <C-o>            find files                               ",
  "   <leader>fg       live grep                                ",
  "   <leader>fo       recent files                             ",
  "   <leader>fb       open buffers                             ",
  " ─────────────────────────────────────────────────────────── ",
  "  HARPOON                                                    ",
  "   <C-g>            add current file                         ",
  "   <C-q>            quick menu                               ",
  "   <C-1> … <C-9>   jump to harpoon slot 1–9                 ",
  " ─────────────────────────────────────────────────────────── ",
  "  EDITING                                                    ",
  "   J / K  (visual)  move selection down / up                 ",
  "   J       (normal) join lines (cursor stays in place)       ",
  "   <leader>p        paste without overwriting buffer         ",
  "   <leader>D        delete without overwriting buffer        ",
  "   <leader>Y        yank to system clipboard                 ",
  "   <leader>P        paste from system clipboard              ",
  "   <leader>s        search-replace word under cursor         ",
  " ─────────────────────────────────────────────────────────── ",
  "  LSP  (Python — run :LspEnable or <leader>le first)         ",
  "   gd               go to definition                         ",
  "   ]d / [d          next / prev diagnostic                   ",
  "   K                diagnostic popup or hover docs           ",
  "   <leader>K        all diagnostics in location list         ",
  "   grn              rename symbol   (nvim 0.11 default)      ",
  "   gra              code action     (nvim 0.11 default)      ",
  "   grr              references      (nvim 0.11 default)      ",
  "   gri              implementation  (nvim 0.11 default)      ",
  " ─────────────────────────────────────────────────────────── ",
  "  TERMINAL                                                   ",
  "   <C-Esc>          exit terminal mode                       ",
  " ─────────────────────────────────────────────────────────── ",
  "  FINDING MORE                                               ",
  "   :help index       full list of built-in normal bindings   ",
  "   :help motion      movement commands                       ",
  "   :help operator    operators (d, c, y, …)                  ",
  "   :map              all active custom mappings (current buf) ",
  "   :nmap / :vmap     normal / visual custom mappings         ",
  "   q  (this window)  close cheatsheet                        ",
  " ─────────────────────────────────────────────────────────── ",
}

local function open_cheatsheet()
  -- dimensions
  local width  = 62
  local height = #lines

  local row = math.floor((vim.o.lines   - height) / 2)
  local col = math.floor((vim.o.columns - width)  / 2)

  -- scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = "cheatsheet"

  -- highlight groups (soft, no colour dependency)
  vim.api.nvim_buf_add_highlight(buf, -1, "Title",   0, 0, -1)  -- header
  for i, line in ipairs(lines) do
    if line:match("^%s*─") then
      vim.api.nvim_buf_add_highlight(buf, -1, "Comment", i - 1, 0, -1)
    elseif line:match("^%s+[A-Z %/&]+%s*$") then
      vim.api.nvim_buf_add_highlight(buf, -1, "Statement", i - 1, 0, -1)
    end
  end

  -- floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width    = width,
    height   = height,
    row      = row,
    col      = col,
    style    = "minimal",
    border   = "rounded",
    title    = " cheatsheet ",
    title_pos = "center",
  })

  vim.wo[win].cursorline = false
  vim.wo[win].wrap       = false

  -- close with q or <Esc>
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function() vim.api.nvim_win_close(win, true) end, {
      buffer = buf, nowait = true, silent = true,
    })
  end
end

vim.api.nvim_create_user_command("Cheatsheet", open_cheatsheet, {
  desc = "Show custom keybindings cheatsheet",
})

vim.keymap.set("n", "<leader>?", open_cheatsheet, { desc = "Cheatsheet: custom keybindings" })
