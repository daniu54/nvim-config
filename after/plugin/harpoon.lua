local ok, harpoon = pcall(require, 'harpoon')
if not ok then return end

harpoon:setup()

-- <leader>g: add current file to harpoon list
vim.keymap.set('n', '<leader>g', function() harpoon:list():add() end, { desc = 'Harpoon: add file' })

-- <C-g>: toggle harpoon quick menu
-- (add-file moved to <leader>g; menu was <C-q> then briefly <leader>h. <C-q> is
--  now "close tmux pane" in the terminal.)
vim.keymap.set('n', '<C-g>', function() harpoon.ui:toggle_quick_menu(harpoon:list()) end, { desc = 'Harpoon: quick menu' })

-- <C-1> through <C-9>: jump to harpoon slot
-- mirrors VSCode ctrl+1-9 (vscode-harpoon.gotoEditor1-9)
-- Note: requires terminal support for ctrl+number keys (works in Windows Terminal)
for i = 1, 9 do
    vim.keymap.set('n', '<C-' .. i .. '>', function()
        harpoon:list():select(i)
    end, { desc = 'Harpoon: go to file ' .. i })
end
