local ok, telescope = pcall(require, 'telescope')
if not ok then return end

telescope.setup({})

local builtin = require('telescope.builtin')

-- <C-o>: find files — mirrors VSCode ctrl+o (quickOpen → file picker)
-- NOTE: overrides nvim's built-in <C-o> (jumplist back)
vim.keymap.set('n', '<C-o>', builtin.find_files, { desc = 'Telescope: find files' })

-- <leader>fg: live grep
vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Telescope: live grep' })

-- <leader>fo: recent files — mirrors VSCode ctrl+shift+o (openRecent)
vim.keymap.set('n', '<leader>fo', builtin.oldfiles, { desc = 'Telescope: recent files' })

-- <leader>fb: open buffers
vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Telescope: buffers' })
