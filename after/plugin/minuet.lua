-- AI-based inline completion (typeahead), similar to GitHub Copilot, powered by
-- Claude (Anthropic) via minuet-ai.nvim: https://github.com/milanglacier/minuet-ai.nvim
--
-- See after/plugin/copilot.lua for the GitHub Copilot equivalent — both share
-- the opt-in-per-directory infrastructure in lua/shared/ai_completion.lua.
-- Don't enable both engines for the same project: they share the same
-- keymaps below (deliberately, so muscle memory transfers), so whichever
-- plugin's after/plugin/*.lua runs last wins the keymap.
--
-- Env vars required:
--   ANTHROPIC_API_KEY  — your Claude API key, from https://console.anthropic.com/settings/keys
--                         Stored in ~/.zshrc.secrets (gitignored/untracked, mode 600,
--                         sourced by ~/.zshrc). Edit it with the `zshsecrets` alias.
--
-- A saner alternative for later: instead of a long-lived key sitting in a plaintext
-- env var, use an OS keychain / secret manager (e.g. `pass`, `secret-tool`, Bitwarden
-- CLI already used for other secrets in this setup — see ~/.zshrc.bitwarden) and have
-- the api_key option below be a function that fetches the key on demand instead of an
-- env var name. Not implemented here per current request — env var only, for now.
--
-- DEFAULT STATE: no AI, anywhere. `virtualtext.auto_trigger_ft = {}` means nothing
-- auto-suggests in any filetype/directory unless explicitly turned on (see below).
--
-- OPT-IN PER DIRECTORY: press <leader>la (or :EnableProjectAi) in the project you
-- want this enabled for. That writes/trusts/sources a `.nvim.lua` at the project
-- root (see lua/shared/ai_completion.lua) which runs `Minuet virtualtext enable`
-- for every filetype from then on, in this session and future ones. `exrc` is
-- enabled (lua/shared/set.lua) and nvim prompts to trust an unfamiliar project's
-- `.nvim.lua` before running it, so this never happens silently for a repo you
-- didn't opt in yourself.
--
-- Even without opting a directory in, completions can always be requested manually
-- with the `next`/`prev` keymaps below (they trigger a completion request even when
-- the current filetype isn't auto-triggering).
--
-- SENSITIVE FILES: regardless of directory opt-in, buffers matching
-- shared.ai_completion's `sensitive_patterns` always have virtualtext
-- force-disabled, so their contents are never sent to the API as completion
-- context.
local ai = require('shared.ai_completion')

require('minuet').setup({
    provider = 'claude',
    virtualtext = {
        auto_trigger_ft = {},   -- opt-in only, see comment above
        keymap = {
            accept      = '<A-a>',
            accept_line = '<A-l>',
            next        = '<A-]>',  -- also manually triggers a completion request
            prev        = '<A-[>',  -- also manually triggers a completion request
            dismiss     = '<A-e>',
        },
    },
    provider_options = {
        claude = {
            model = 'claude-haiku-4-5', -- fast/cheap model, good fit for as-you-type completion
            api_key = 'ANTHROPIC_API_KEY', -- name of the env var, NOT the key itself
            end_point = 'https://api.anthropic.com/v1/messages',
            max_tokens = 256,
            stream = true,
        },
    },
})

vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    callback = function(args)
        if ai.is_sensitive(args.buf) then
            vim.cmd('Minuet virtualtext disable')
        end
    end,
})

local function enable_claude_project_wide()
    local root = ai.enable_project_wide('-- minuet-ai (Claude) project-wide enable', {
        "vim.api.nvim_create_augroup('ai_completion_minuet', { clear = true })",
        "vim.api.nvim_create_autocmd('FileType', {",
        "    group = 'ai_completion_minuet',",
        "    pattern = '*',",
        "    callback = function(args)",
        "        if not vim.bo[args.buf].buflisted then return end",
        "        vim.cmd('Minuet virtualtext enable')",
        '    end,',
        '})',
    })
    vim.notify('Claude AI completion enabled project-wide for ' .. root, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('EnableProjectAi', enable_claude_project_wide, {
    desc = 'Create/trust/source .nvim.lua to enable Claude AI completion for this project',
})

vim.keymap.set('n', '<leader>la', enable_claude_project_wide, { desc = 'Enable Claude AI completion for this project' })
