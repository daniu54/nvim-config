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
                'CopilotChatOptimize', 'CopilotChatDocs', 'CopilotChatTests', 'CopilotChatCommit',
                'CopilotChatModels', 'CopilotChatPrompts', 'CopilotChatToggle', 'CopilotChatOpen',
                'CopilotChatClose', 'CopilotChatStop', 'CopilotChatReset', 'CopilotChatSave',
                'CopilotChatLoad' },
        opts = {},
        -- GitHub restricted Copilot Free/Student plans to "auto" model
        -- selection only (2026-06-24), which upstream CopilotChat.nvim
        -- (as of the pinned commit) can't fully drive yet: `auto` fails
        -- with "Model not found"/"Resolved model not found" because the
        -- model list is filtered to model_picker_enabled (false for every
        -- real model on these accounts), and the resolved backing model
        -- needs a `Copilot-Session-Token` header that the client never
        -- captures. See patches/copilotchat-auto-model.patch for the fix
        -- (based on unmerged upstream PRs #1575 and #1577) and CLAUDE.md
        -- ("AI completion (Copilot)") for the full story. Applied after
        -- every install/update; a no-op once upstream fixes this properly.
        build = function(plugin)
            local patch = vim.fn.stdpath('config') .. '/patches/copilotchat-auto-model.patch'
            local function git(args)
                return vim.system(vim.list_extend({ 'git' }, args), { cwd = plugin.dir }):wait()
            end
            if git({ 'apply', '--reverse', '--check', patch }).code == 0 then
                return -- already applied
            end
            if git({ 'apply', '--check', patch }).code == 0 then
                git({ 'apply', patch })
                vim.notify('Applied local auto-model fix to CopilotChat.nvim', vim.log.levels.INFO)
            else
                vim.notify(
                    'CopilotChat.nvim auto-model patch no longer applies cleanly — ' ..
                    'check patches/copilotchat-auto-model.patch (upstream may have changed or fixed this)',
                    vim.log.levels.WARN
                )
            end
        end,
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
