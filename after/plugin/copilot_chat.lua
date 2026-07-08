-- Region refactor via GitHub Copilot Chat: select code, describe the change
-- in plain English, get a diff back — the Neovim equivalent of VS Code's
-- inline chat (Ctrl+I). Uses CopilotChat.nvim:
-- https://github.com/CopilotC-Nvim/CopilotChat.nvim
--
-- CopilotChat.nvim rides on the same GitHub OAuth session as copilot.lua
-- (see after/plugin/copilot.lua) — no separate auth step, but `:Copilot auth`
-- must have been run at least once.
--
-- Lazy-loaded on first use of any :CopilotChat* command (see lua/shared/lazy.lua),
-- so — like copilot.lua's language server — nothing extra starts up just
-- because this file is sourced.
local ai = require('shared.copilot')

-- <leader>lr in visual mode: keeps the selection (so CopilotChat's default
-- `selection = 'visual'` picks up the `'<`/`'>` marks) and drops into the
-- command line pre-filled with `:CopilotChat `, cursor ready for you to type
-- what you want changed. Press <CR> to send it.
--
-- The reply lands in a chat split with a diff for the selected region;
-- `<C-y>` in that split (CopilotChat's default `accept_diff` mapping) applies
-- it back over your original selection. `gd` shows the diff again, `gy`
-- yanks it, `q` closes the split without applying anything.
vim.keymap.set('v', '<leader>lr', function()
    if ai.is_sensitive(0) then
        vim.notify('Copilot chat disabled for this file (matches a sensitive-file pattern)', vim.log.levels.WARN)
        return ''
    end
    return ':CopilotChat '
end, { expr = true, desc = 'Copilot: describe a refactor for the selected code' })
