-- AI-based inline completion (typeahead) via GitHub Copilot, using
-- copilot.lua: https://github.com/zbirenbaum/copilot.lua
--
-- See ../../CLAUDE.md ("AI completion (Copilot)") for the overall approach:
-- opt-in per project via a trusted `.nvim.lua`, nothing sent anywhere by
-- default. See after/plugin/copilot_chat.lua for the region-refactor feature
-- built on top of this same bootstrap.
--
-- No env var / API key file needed here. Auth is GitHub OAuth device-code
-- flow, requested from inside nvim:
--   1. `:Copilot auth`  — prints a URL + one-time code.
--   2. Visit https://github.com/login/device in any browser, sign in with the
--      GitHub account that has Copilot access (e.g. via GitHub Student
--      Developer Pack -> Copilot), enter the code.
--   3. `:Copilot status` to confirm.
-- The resulting token is cached under ~/.config/github-copilot/ automatically
-- — nothing to type into a secrets file yourself (see ~/.zshrc.secrets).
--
-- Node.js >= 22 is required to run the bundled copilot-language-server. In
-- this environment `node` is a zsh alias to Windows node.exe (see
-- ~/.claude/CLAUDE.md) — that alias only exists in an interactive shell, so
-- nvim's job spawner can't see it, and the apt-installed /usr/bin/node is only
-- v18. A native Linux Node 22 was installed via nvm for this
-- (`nvm install 22`); lua/shared/copilot.lua points straight at that binary.
local ai = require('shared.copilot')

-- <leader>la: opt the current project into Copilot, project-wide.
--
-- Copilot's client only attaches to buffers that pass its `filetypes`/
-- `should_attach` check — and force-attaching (bypassing that check) is
-- exactly how `filetypes['*'] = false` gets overridden per project. So the
-- sensitive-file check has to happen *before* attaching, in the same FileType
-- callback that opts a project in, rather than as a separate disable pass.
local function enable_copilot_project_wide()
    ai.ensure_ready()

    local root = ai.enable_project_wide('-- copilot project-wide enable', {
        "vim.api.nvim_create_augroup('ai_completion_copilot', { clear = true })",
        "vim.api.nvim_create_autocmd('FileType', {",
        "    group = 'ai_completion_copilot',",
        "    pattern = '*',",
        "    callback = function(args)",
        "        if not vim.bo[args.buf].buflisted then return end",
        "        if require('shared.copilot').is_sensitive(args.buf) then return end",
        "        require('shared.copilot').ensure_ready()",
        "        require('copilot.command').attach({ force = true, bufnr = args.buf })",
        "        vim.b.copilot_suggestion_auto_trigger = true",
        '    end,',
        '})',
    })

    -- The FileType autocmd above only fires for buffers opened from now on —
    -- the buffer you pressed <leader>la in already had its FileType event
    -- fire before .nvim.lua existed, so without this it stays un-attached
    -- until you switch away and back.
    if vim.bo.buflisted and not ai.is_sensitive(0) then
        require('copilot.command').attach({ force = true, bufnr = 0 })
        vim.b.copilot_suggestion_auto_trigger = true
    end

    vim.notify('Copilot enabled project-wide for ' .. root, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('EnableProjectCopilot', enable_copilot_project_wide, {
    desc = 'Create/trust/source .nvim.lua to enable Copilot for this project',
})

vim.keymap.set('n', '<leader>la', enable_copilot_project_wide, { desc = 'Enable Copilot for this project' })
