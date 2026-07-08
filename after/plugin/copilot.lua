-- AI-based inline completion (typeahead) via GitHub Copilot, using
-- copilot.lua: https://github.com/zbirenbaum/copilot.lua
--
-- See after/plugin/minuet.lua for the Claude equivalent — both share the
-- opt-in-per-directory infrastructure in lua/shared/ai_completion.lua and the
-- same accept/next/prev/dismiss keymaps. Don't enable both engines for the
-- same project: whichever plugin's after/plugin/*.lua runs last wins the
-- keymap (alphabetically, this file loads before minuet.lua).
--
-- No env var / API key file needed here. Auth is GitHub OAuth device-code
-- flow, requested from inside nvim:
--   1. `:Copilot auth`  — prints a URL + one-time code.
--   2. Visit https://github.com/login/device in any browser, sign in with the
--      GitHub account that has Copilot access (e.g. via GitHub Student
--      Developer Pack -> Copilot), enter the code.
--   3. `:Copilot status` to confirm.
-- The resulting token is cached under ~/.config/github-copilot/ automatically
-- — nothing to type into a secrets file yourself.
--
-- Node.js >= 22 is required to run the bundled copilot-language-server. In
-- this environment `node` is a zsh alias to Windows node.exe (see
-- ~/.claude/CLAUDE.md) — that alias only exists in an interactive shell, so
-- nvim's job spawner can't see it, and the apt-installed /usr/bin/node is only
-- v18. A native Linux Node 22 was installed via nvm for this
-- (`nvm install 22`); lua/shared/copilot_ai.lua points straight at that binary.
--
-- IMPORTANT: require('copilot').setup() starts the copilot-language-server
-- Node process immediately, even for filetypes it will never attach to. It
-- must NOT be called here at file-load time (that would mean every nvim
-- instance spawns a Node process on startup, opted in or not) — it's called
-- lazily, once, via require('shared.copilot_ai').ensure_ready() from inside
-- the opt-in path below.
local ai = require('shared.ai_completion')

-- <leader>lc: opt the current project into Copilot, project-wide.
--
-- Unlike Minuet (which can force-disable an already-attached buffer),
-- Copilot's client only attaches to buffers that pass its `filetypes`/
-- `should_attach` check — and force-attaching (bypassing that check) is
-- exactly how `filetypes['*'] = false` gets overridden per project. So the
-- sensitive-file check has to happen *before* attaching, in the same FileType
-- callback that opts a project in, rather than as a separate disable pass.
local function enable_copilot_project_wide()
    require('shared.copilot_ai').ensure_ready()

    local root = ai.enable_project_wide('-- copilot project-wide enable', {
        "vim.api.nvim_create_augroup('ai_completion_copilot', { clear = true })",
        "vim.api.nvim_create_autocmd('FileType', {",
        "    group = 'ai_completion_copilot',",
        "    pattern = '*',",
        "    callback = function(args)",
        "        if not vim.bo[args.buf].buflisted then return end",
        "        if require('shared.ai_completion').is_sensitive(args.buf) then return end",
        "        require('shared.copilot_ai').ensure_ready()",
        "        require('copilot.command').attach({ force = true, bufnr = args.buf })",
        "        vim.b.copilot_suggestion_auto_trigger = true",
        '    end,',
        '})',
    })
    vim.notify('Copilot enabled project-wide for ' .. root, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('EnableProjectCopilot', enable_copilot_project_wide, {
    desc = 'Create/trust/source .nvim.lua to enable Copilot for this project',
})

vim.keymap.set('n', '<leader>lc', enable_copilot_project_wide, { desc = 'Enable Copilot for this project' })
