-- lazy.nvim (replaces packer)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local out = vim.fn.system({
        "git", "clone", "--filter=blob:none",
        "--branch=stable",
        "https://github.com/folke/lazy.nvim.git",
        lazypath,
    })
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
            { out,                            "WarningMsg" },
        }, true, {})
        vim.fn.getchar()
        os.exit(1)
    end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
    -- colorscheme
    { 'rose-pine/neovim', name = 'rose-pine' },

    -- telescope
    {
        'nvim-telescope/telescope.nvim',
        branch = 'master',
        dependencies = { 'nvim-lua/plenary.nvim' },
    },

    -- harpoon2
    {
        'ThePrimeagen/harpoon',
        branch = 'harpoon2',
        dependencies = { 'nvim-lua/plenary.nvim' },
    },

    -- completion
    'hrsh7th/nvim-cmp',

    -- AI-based inline completion via GitHub Copilot, see after/plugin/copilot.lua
    -- (loaded eagerly, not lazy on the :Copilot cmd, since after/plugin/copilot.lua
    -- calls require('copilot').setup() unconditionally at startup like the other
    -- completion plugins in this config)
    'zbirenbaum/copilot.lua',

    -- Copilot Chat: region-refactor / ask-Copilot-a-question, see
    -- after/plugin/copilot_chat.lua. Lazy-loaded on its own commands, unlike
    -- copilot.lua above, since it's an occasional-use feature rather than
    -- always-on completion.
    {
        'CopilotC-Nvim/CopilotChat.nvim',
        branch = 'main',
        dependencies = { 'zbirenbaum/copilot.lua', 'nvim-lua/plenary.nvim' },
        cmd = { 'CopilotChat', 'CopilotChatExplain', 'CopilotChatReview', 'CopilotChatFix',
                'CopilotChatOptimize', 'CopilotChatDocs', 'CopilotChatTests', 'CopilotChatCommit' },
        opts = {},
    },

    -- comments
    {
        'numToStr/Comment.nvim',
        config = function()
            require('Comment').setup({
                mappings = { extra = false },
            })
            -- <leader>c: toggle line comment on each selected line
            vim.keymap.set("v", "<leader>c", "<Plug>(comment_toggle_linewise_visual)",
                { desc = "Toggle line comment" })
            -- <leader>C: toggle block comment around the selection
            vim.keymap.set("v", "<leader>C", "<Plug>(comment_toggle_blockwise_visual)",
                { desc = "Toggle block comment" })
        end,
    },

    -- treesitter (syntax highlighting + folding)
    {
        'nvim-treesitter/nvim-treesitter',
        tag = 'v0.9.3',
        build = ':TSUpdate',
        config = function()
            require('nvim-treesitter.configs').setup({
                ensure_installed = { 'javascript', 'typescript', 'tsx', 'lua', 'markdown', 'markdown_inline', 'yaml', 'zig' },
                highlight = { enable = true },
            })
        end,
    },

    -- sqlite backend (used by neoclip for persistent yank history)
    { 'kkharji/sqlite.lua' },

    -- yank history picker (telescope extension)
    {
        'AckslD/nvim-neoclip.lua',
        dependencies = { 'nvim-lua/plenary.nvim', 'kkharji/sqlite.lua' },
        config = function()
            require('neoclip').setup({
                -- Persist yank history to SQLite so it survives restarts and is
                -- shared between all nvim instances (outer terminal nvim + inner nvim).
                enable_persistent_history = true,
                db_path = vim.fn.stdpath('data') .. '/neoclip.sqlite3',
                -- Keep up to 1000 entries in the persistent store.
                db_max_entries = 1000,
            })
        end,
    },

    -- document structure sidebar (classes, functions, etc.)
    {
        'stevearc/aerial.nvim',
        branch = 'nvim-0.11',
        dependencies = { 'nvim-treesitter/nvim-treesitter' },
        config = function()
            require('aerial').setup({
                backends = { 'treesitter', 'lsp' },
                layout = {
                    default_direction = 'left',
                    min_width = 30,
                },
                show_guides = true,
                attach_mode = 'global',
                close_automatic_events = { 'unsupported' },
            })
            vim.api.nvim_create_autocmd('FileType', {
                pattern = 'aerial',
                callback = function() vim.wo.number = true end,
            })
            vim.keymap.set('n', '<leader>a', '<cmd>AerialToggle<CR>',
                { desc = 'Toggle document outline (aerial)' })
        end,
    },

    -- obsidian notes integration
    {
        'epwalsh/obsidian.nvim',
        version = '*',
        lazy = false,
        dependencies = { 'nvim-lua/plenary.nvim' },
    },

    -- formatter
    'stevearc/conform.nvim',

    -- neater keymaps
    'b0o/mapx.nvim',

    -- lsp
    {
        'VonHeikemen/lsp-zero.nvim',
        branch = 'v1.x',
        dependencies = {
            'neovim/nvim-lspconfig',
            { 'williamboman/mason.nvim', build = ':MasonUpdate' },
            'williamboman/mason-lspconfig.nvim',
            'hrsh7th/nvim-cmp',
            'hrsh7th/cmp-nvim-lsp',
            'hrsh7th/cmp-buffer',
            'hrsh7th/cmp-path',
            'saadparwaiz1/cmp_luasnip',
            'hrsh7th/cmp-nvim-lua',
            'L3MON4D3/LuaSnip',
            'rafamadriz/friendly-snippets',
        },
    },
})
