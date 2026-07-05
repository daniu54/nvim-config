-- Initialize Mason so :Mason and :MasonInstall commands are available
require('mason').setup()

-- Python LSP (pyright) is NOT started automatically.
-- This keeps file-open times fast. Enable it on demand when you need
-- language-aware completions, go-to-definition, etc.
--
-- One-time setup: install pyright via :MasonInstall pyright
-- Then run :LspEnable (or <leader>le) in any Python file.
--
-- Venv detection: poetry is Windows-side (poetry.exe) with virtualenvs.in-project = true,
-- so .venv is always in the project root as a Windows venv (Scripts/python.exe layout).
-- We use venvPath + venv in pyright settings so pyright scans the folder directly —
-- no interpreter call needed, works transparently through WSL /mnt/d/ paths.

local function on_attach(_, bufnr)
    local map = function(key, fn, desc)
        vim.keymap.set('n', key, fn, { buffer = bufnr, desc = desc })
    end

    -- go to definition (not a nvim default)
    map('gd', vim.lsp.buf.definition, 'LSP: go to definition')

    -- diagnostics
    map(']d', function() vim.diagnostic.jump({ count = 1 }) end,  'LSP: next diagnostic')
    map('[d', function() vim.diagnostic.jump({ count = -1 }) end, 'LSP: prev diagnostic')

    -- K: show diagnostic popup if there's a warning/error on this line, otherwise hover docs
    map('K', function()
        local lnum = vim.fn.line('.') - 1  -- 0-indexed
        local diags = vim.diagnostic.get(vim.api.nvim_get_current_buf(), { lnum = lnum })
        if #diags > 0 then
            vim.diagnostic.open_float()
        else
            vim.lsp.buf.hover()
        end
    end, 'LSP: diagnostic popup or hover docs')

    -- <leader>K: all diagnostics in location list
    map('<leader>K', vim.diagnostic.setloclist, 'LSP: all diagnostics list')

    -- error-only navigation + expand
    map('gn', function() vim.diagnostic.jump({ count = 1, severity = vim.diagnostic.severity.ERROR }) end,
        'LSP: next error')
    map('gp', function() vim.diagnostic.jump({ count = -1, severity = vim.diagnostic.severity.ERROR }) end,
        'LSP: prev error')
    map('ge', function() vim.diagnostic.open_float(nil, { severity = vim.diagnostic.severity.ERROR }) end,
        'LSP: expand error under cursor')

    -- nvim 0.11 sets these by default, listed here for reference:
    -- grn        → rename symbol
    -- gra        → code action
    -- grr        → references
    -- gri        → implementation
end

local function lsp_enable_python()
    -- Prefer Mason-installed binary, fall back to system PATH
    local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/pyright-langserver'
    local cmd = vim.fn.executable(mason_bin) == 1 and mason_bin or 'pyright-langserver'

    local root = vim.fs.dirname(
        vim.fs.find({ 'pyproject.toml', 'setup.py', 'setup.cfg', '.git' }, { upward = true })[1]
    ) or vim.uv.cwd()

    -- Find site-packages directly inside .venv, handling both layouts:
    --   Windows venv (poetry.exe): .venv/Lib/site-packages
    --   Linux venv  (poetry):      .venv/lib/pythonX.Y/site-packages
    -- Using extraPaths bypasses pyvenv.cfg entirely (which contains Windows paths
    -- that pyright can't follow when running on Linux).
    local extra_paths = {}
    local venv_msg = 'none (system python)'

    local win_packages = root .. '/.venv/Lib/site-packages'
    if vim.fn.isdirectory(win_packages) == 1 then
        extra_paths = { win_packages }
        venv_msg = win_packages
    else
        local matches = vim.fn.glob(root .. '/.venv/lib/python*/site-packages', false, true)
        if #matches > 0 then
            extra_paths = { matches[1] }
            venv_msg = matches[1]
        end
    end

    vim.lsp.start({
        name     = 'pyright',
        cmd      = { cmd, '--stdio' },
        root_dir = root,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        on_attach = on_attach,
        settings = {
            python = {
                analysis = {
                    typeCheckingMode = 'off',  -- set to 'basic' or 'strict' if you want type errors
                    extraPaths = extra_paths,
                },
            },
        },
    })

    vim.notify('LSP (pyright) started\npackages: ' .. venv_msg, vim.log.levels.INFO)
end

-- Zig LSP (zls). One-time setup: install via :MasonInstall zls
-- zig itself is managed by anyzig (Windows-side, D:/zig) and is only
-- resolvable as `zig.exe` (not the shell-only `zig` alias), so we point
-- zls at it explicitly via the zig_exe_path setting.
local function lsp_enable_zig()
    local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/zls'
    local cmd = vim.fn.executable(mason_bin) == 1 and mason_bin or 'zls'

    if vim.fn.executable(cmd) == 0 then
        vim.notify('zls not found. Run :MasonInstall zls first.', vim.log.levels.ERROR)
        return
    end

    local zig_exe_path = vim.fn.exepath('zig.exe')
    if zig_exe_path == '' then
        vim.notify('zig.exe not found on $PATH', vim.log.levels.ERROR)
        return
    end

    local root = vim.fs.dirname(
        vim.fs.find({ 'build.zig', '.git' }, { upward = true })[1]
    ) or vim.uv.cwd()

    vim.lsp.start({
        name = 'zls',
        cmd = { cmd },
        root_dir = root,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        on_attach = on_attach,
        settings = {
            zls = {
                zig_exe_path = zig_exe_path,
            },
        },
    })

    vim.notify('LSP (zls) started\nzig: ' .. zig_exe_path, vim.log.levels.INFO)
end

local function lsp_enable()
    local ft = vim.bo.filetype
    if ft == 'python' then
        lsp_enable_python()
    elseif ft == 'zig' then
        lsp_enable_zig()
    else
        vim.notify('LspEnable: no LSP configured for filetype "' .. ft .. '"', vim.log.levels.WARN)
    end
end

vim.api.nvim_create_user_command('LspEnable', lsp_enable, {
    desc = 'Start LSP for current buffer (Python: pyright, Zig: zls)',
})

vim.keymap.set('n', '<leader>le', lsp_enable, { desc = 'Enable LSP for current buffer' })
