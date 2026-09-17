local ok, obsidian = pcall(require, 'obsidian')
if not ok then return end

-- No vault configured on this machine yet — obsidian.setup() hard-errors
-- (FileNotFoundError) at startup if the workspace path doesn't exist, which
-- would break every nvim launch. Skip setup until one is pointed here, e.g.
-- via OBSIDIAN_VAULT_DIR.
local vault = vim.env.OBSIDIAN_VAULT_DIR
if not vault or vim.fn.isdirectory(vault) == 0 then return end

obsidian.setup({
    workspaces = {
        {
            name = 'default',
            path = vault,
        },
    },
    -- use telescope for search/picker
    picker = { name = 'telescope.nvim' },
    -- follow links with gf
    follow_url_func = function(url)
        vim.fn.jobstart({ 'open', url })
    end,
    ui = { enable = true },
})
