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

-- Hover documentation. Wraps the same request/float that vim.lsp.buf.hover()
-- uses, but some servers (e.g. zls) put "Go to [X](file://path#Lnum)" links in
-- the hover markdown, and core's floating preview has no way to act on a link
-- inside it. This adds a buffer-local <CR> in the float that parses the link
-- under the cursor and jumps straight to that file/line.
local function hover()
    local bufnr = vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/hover' })
    if #clients == 0 then
        vim.notify('No LSP client supports hover', vim.log.levels.WARN)
        return
    end

    local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
    clients[1]:request('textDocument/hover', params, function(err, result)
        if err then
            vim.notify(tostring(err), vim.log.levels.ERROR)
            return
        end
        if not result or not result.contents then
            vim.notify('No information available')
            return
        end
        local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
        if vim.tbl_isempty(lines) then
            vim.notify('No information available')
            return
        end

        -- focus_id: pressing gi again focuses the existing float instead of
        -- re-opening it (same toggle behavior as core vim.lsp.buf.hover())
        local _, winid = vim.lsp.util.open_floating_preview(lines, 'markdown', {
            border = 'rounded',
            focus_id = 'gi_hover',
        })

        -- a real (floating) window has relative ~= ''; when gi toggles focus
        -- BACK to the source window, open_floating_preview returns that
        -- window instead, so skip touching its keymaps
        if vim.api.nvim_win_get_config(winid).relative == '' then
            return
        end

        vim.keymap.set('n', '<CR>', function()
            local url = vim.api.nvim_get_current_line():match('%[.-%]%((.-)%)')
            if not url then return end
            local path, frag = url:match('^(.-)#(.*)$')
            path = (path or url):gsub('^file://', '')
            local lnum = frag and tonumber(frag:match('L(%d+)'))
            vim.api.nvim_win_close(winid, true)
            vim.cmd.tabedit(vim.fn.fnameescape(path))
            if lnum then
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            end
        end, { buffer = vim.api.nvim_win_get_buf(winid), desc = 'LSP hover: follow link under cursor' })
    end, bufnr)
end

local function on_attach(_, bufnr)
    local map = function(key, fn, desc)
        vim.keymap.set('n', key, fn, { buffer = bufnr, desc = desc })
    end

    -- go to definition (not a nvim default)
    map('gd', vim.lsp.buf.definition, 'LSP: go to definition')

    -- hover documentation (always hover, unlike K which can show diagnostics instead)
    -- press gi again to focus the float; <CR> on a "Go to [X](...)" link follows it
    map('gi', hover, 'LSP: hover documentation (<CR> on a link to follow it)')

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
            hover()
        end
    end, 'LSP: diagnostic popup or hover docs')

    -- <leader>K: all diagnostics in location list
    map('<leader>K', vim.diagnostic.setloclist, 'LSP: all diagnostics list')

    -- diagnostic navigation + expand (mirrors ]d/[d, kept as separate mnemonic keys)
    map('gn', function() vim.diagnostic.jump({ count = 1 }) end,  'LSP: next diagnostic')
    map('gp', function() vim.diagnostic.jump({ count = -1 }) end, 'LSP: prev diagnostic')
    map('ge', function() vim.diagnostic.open_float() end, 'LSP: expand diagnostic under cursor')

    -- nvim 0.11 sets these by default, listed here for reference:
    -- grn        → rename symbol
    -- gra        → code action
    -- grr        → references
    -- gri        → implementation
end

-- Tracks which filetypes have had auto-attach wired up already, so
-- <leader>le only needs to be pressed once per session (not once per file)
-- to get LSP on every buffer of that type opened afterwards (:e, <C-o>, etc.)
local autostart_registered = {}

local function ensure_autostart(ft, start_fn)
    if autostart_registered[ft] then return end
    autostart_registered[ft] = true

    vim.api.nvim_create_autocmd('FileType', {
        pattern = ft,
        callback = function() start_fn(true) end,
    })
end

local function lsp_enable_python(quiet)
    -- Prefer Mason-installed binary, fall back to system PATH
    local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/pyright-langserver'
    local cmd = vim.fn.executable(mason_bin) == 1 and mason_bin or 'pyright-langserver'

    -- search upward from the buffer's own directory, not nvim's cwd (which
    -- may not match if nvim wasn't launched from inside the project)
    local root = vim.fs.dirname(
        vim.fs.find({ 'pyproject.toml', 'setup.py', 'setup.cfg', '.git' }, {
            upward = true,
            path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
        })[1]
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

    if not quiet then
        vim.notify('LSP (pyright) started\npackages: ' .. venv_msg, vim.log.levels.INFO)
    end

    ensure_autostart('python', lsp_enable_python)
end

-- Zig LSP (zls). One-time setup: install via :MasonInstall zls
--
-- zls resolves zig_exe_path by running `<zig_exe_path> env` and trusting the
-- self-reported paths (zig_exe, lib_dir, ...) unconditionally, even
-- overwriting whatever zig_exe_path we hand it. `zig.exe` on $PATH is the
-- Windows-side anyzig binary (D:/zig) — a native Windows exe that always
-- self-reports Windows-style paths (D:\...), which zls (a Linux binary)
-- can't open or exec. That breaks everything downstream: std lib resolution,
-- `zig ast-check` diagnostics, `build-exe --show-builtin`, and therefore
-- hover into std (e.g. `gi` on `std.mem.Allocator` silently returns nothing).
--
-- Fix: use a second, Linux-native anyzig binary (~/bin/zig-linux) purely for
-- zls/editor tooling. It reads the same build.zig.zon and resolves the same
-- pinned zig version, but as a Linux binary it self-reports Linux paths, so
-- zls's canonicalization no longer breaks. Building/running the project
-- still goes through the Windows zig.exe — this only affects the LSP.
local function lsp_enable_zig(quiet)
    local mason_bin = vim.fn.stdpath('data') .. '/mason/bin/zls'
    local cmd = vim.fn.executable(mason_bin) == 1 and mason_bin or 'zls'

    if vim.fn.executable(cmd) == 0 then
        vim.notify('zls not found. Run :MasonInstall zls first.', vim.log.levels.ERROR)
        return
    end

    local zig_exe_path = vim.fn.exepath('zig-linux')
    if zig_exe_path == '' then
        vim.notify('zig-linux not found on $PATH (Linux anyzig build for zls)', vim.log.levels.ERROR)
        return
    end

    -- search upward from the buffer's own directory, not nvim's cwd (which
    -- may not match if nvim wasn't launched from inside the project) —
    -- also critical here since anyzig needs cwd inside the project to
    -- resolve build.zig.zon's pinned version at all
    local root = vim.fs.dirname(
        vim.fs.find({ 'build.zig', '.git' }, {
            upward = true,
            path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
        })[1]
    ) or vim.uv.cwd()

    vim.lsp.start({
        name = 'zls',
        cmd = { cmd },
        cmd_cwd = root,
        root_dir = root,
        capabilities = require('cmp_nvim_lsp').default_capabilities(),
        on_attach = on_attach,
        settings = {
            zls = {
                zig_exe_path = zig_exe_path,
            },
        },
    })

    if not quiet then
        vim.notify('LSP (zls) started\nzig: ' .. zig_exe_path, vim.log.levels.INFO)
    end

    ensure_autostart('zig', lsp_enable_zig)
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
