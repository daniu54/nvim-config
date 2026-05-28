local ok, obsidian = pcall(require, 'obsidian')
if not ok then return end

obsidian.setup({
    workspaces = {
        {
            name = 'default',
            path = '/mnt/d/obsidian_notes/default_vault/default',
        },
    },
    -- use telescope for search/picker
    picker = { name = 'telescope.nvim' },
    -- follow links with gf
    follow_url_func = function(url)
        vim.fn.jobstart({ 'xdg-open', url })
    end,
    ui = { enable = true },
})
