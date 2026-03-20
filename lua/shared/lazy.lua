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

    -- comments
    {
        'numToStr/Comment.nvim',
        config = function()
            require('Comment').setup({
                mappings = { extra = false },
            })
        end,
    },

    -- treesitter (syntax highlighting + folding)
    {
        'nvim-treesitter/nvim-treesitter',
        tag = 'v0.9.3',
        build = ':TSUpdate',
        config = function()
            require('nvim-treesitter.configs').setup({
                ensure_installed = { 'javascript', 'typescript', 'tsx', 'lua', 'markdown', 'markdown_inline' },
                highlight = { enable = true },
            })
        end,
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
