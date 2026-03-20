vim.g.mapleader = " "
vim.g.maplocalleader = ' '

-- terminal
vim.api.nvim_set_keymap('t', '<leader><Esc>', '<C-\\><C-n>', { noremap = true }) 

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
vim.keymap.set("n", "<BS>", "<C-d>")
vim.keymap.set("n", "<leader><BS>", "<C-u>")

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

-- netrw: copy path of file under cursor to Windows clipboard
vim.api.nvim_create_autocmd("FileType", {
  pattern = "netrw",
  callback = function()
    vim.keymap.set("n", "yp", function()
      local path = vim.fn.expand("<cfile>:p")
      vim.fn.system("clip.exe", path)
      vim.notify("Copied: " .. path)
    end, { buffer = true })
  end,
})

-- navigate back and forwards
vim.keymap.set({"n"}, "H", ":bp<CR>", { desc = "Move to previous buffer" })
vim.keymap.set({"n"}, "L", ":bn<CR>", { desc = "Move to next buffer" })
