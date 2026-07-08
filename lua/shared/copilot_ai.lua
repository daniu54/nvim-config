-- Lazy bootstrap for GitHub Copilot (see after/plugin/copilot.lua).
--
-- require('copilot').setup() starts the copilot-language-server Node process
-- immediately, even for filetypes it will never attach to — so it must NOT run
-- at nvim startup, only once a project actually opts in (<leader>lc), otherwise
-- every nvim instance pays that cost regardless of the "no AI by default" design.
local M = {}

local ready = false

local function nvm_node()
    local candidates = vim.fn.glob(vim.fn.expand('~/.nvm/versions/node/*/bin/node'), false, true)
    table.sort(candidates)
    return candidates[#candidates] -- highest-sorted installed version
end

function M.ensure_ready()
    if ready then
        return
    end
    ready = true

    require('copilot').setup({
        copilot_node_command = nvm_node(),
        -- filetypes stays maximally restrictive even post-setup: attaching
        -- still only happens via the explicit force-attach call in
        -- after/plugin/copilot.lua's opt-in autocmd, never automatically.
        filetypes = { ['*'] = false },
        suggestion = {
            auto_trigger = false, -- opt-in only
            keymap = {
                accept      = '<A-a>',
                accept_line = '<A-l>',
                next        = '<A-]>',
                prev        = '<A-[>',
                dismiss     = '<A-e>',
            },
        },
        panel = { enabled = false }, -- ghost-text only, to match minuet's UX
    })
end

return M
