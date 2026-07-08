-- AI-based inline completion (typeahead), similar to GitHub Copilot, powered by
-- Claude (Anthropic) via minuet-ai.nvim: https://github.com/milanglacier/minuet-ai.nvim
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
-- OPT-IN PER DIRECTORY:
-- `exrc` is enabled (lua/shared/set.lua), so a project can opt itself in by adding a
-- `.nvim.lua` file at its root, e.g.:
--
--   -- .nvim.lua (project root, NOT committed to the project's own repo)
--   vim.api.nvim_create_autocmd('FileType', {
--     pattern = { 'python', 'lua', 'typescript' },
--     callback = function() vim.cmd('Minuet virtualtext enable') end,
--   })
--   -- same mechanism works for the on-demand LSP setup in after/plugin/lsp.lua:
--   -- vim.cmd('LspEnable')
--
-- The first time nvim opens a directory containing such a file, it prompts to trust
-- it (:h :trust) before running anything — so an unfamiliar project's `.nvim.lua`
-- never executes silently. Re-run `:trust` if you edit a `.nvim.lua` you already trust.
--
-- Even without opting a directory in, completions can always be requested manually
-- with the `next`/`prev` keymaps below (they trigger a completion request even when
-- the current filetype isn't auto-triggering).
--
-- SENSITIVE FILES: regardless of directory opt-in, buffers matching the patterns
-- below always have virtualtext force-disabled, so their contents are never sent to
-- the API as completion context. Extend `sensitive_patterns` for anything else you
-- keep in plaintext (e.g. this config's own ~/.zshrc.secrets-style files).
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

local sensitive_patterns = {
    '%.env$', '%.env%.', 'secret', 'credential', 'id_rsa', 'id_ed25519',
    '%.pem$', '%.key$', '%.p12$', '%.pfx$', '%.kdbx$', '%.netrc$', '_history$',
    '%.zshrc%.secrets$', '%.zshrc%.bitwarden$',
}

vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    callback = function(args)
        local name = vim.api.nvim_buf_get_name(args.buf):lower()
        for _, pattern in ipairs(sensitive_patterns) do
            if name:match(pattern) then
                vim.cmd('Minuet virtualtext disable')
                return
            end
        end
    end,
})
