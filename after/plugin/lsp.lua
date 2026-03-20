-- Python LSP (pyright) is NOT started automatically.
-- This keeps file-open times fast. Enable it on demand when you need
-- language-aware completions, go-to-definition, etc.
--
-- One-time setup: install pyright via :MasonInstall pyright
-- Then run :LspEnable (or <leader>le) in any Python file.

local function lsp_enable()
    -- Prefer Mason-installed binary, fall back to system PATH
    local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/pyright-langserver'
    local cmd = vim.fn.executable(mason_bin) == 1 and mason_bin or 'pyright-langserver'

    local root = vim.fs.dirname(
        vim.fs.find({ 'pyproject.toml', 'setup.py', 'setup.cfg', '.git' }, { upward = true })[1]
    ) or vim.uv.cwd()

    vim.lsp.start({
        name    = 'pyright',
        cmd     = { cmd, '--stdio' },
        root_dir = root,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        settings = {
            python = {
                analysis = {
                    typeCheckingMode = 'off',  -- set to 'basic' or 'strict' if you want type errors
                },
            },
        },
    })

    vim.notify('LSP (pyright) started — completions now language-aware', vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('LspEnable', lsp_enable, {
    desc = 'Start pyright LSP for current buffer (Python)',
})

vim.keymap.set('n', '<leader>le', lsp_enable, { desc = 'Enable pyright LSP' })
