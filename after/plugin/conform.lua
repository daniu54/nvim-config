local conform = require("conform")

local prettier_cmd = vim.fn.expand("~/.npm-global/bin/prettier")

-- 10s, not the 2s this used to be: prettier takes ~2s on a 400KB minified html
-- file, and unminifying one is what <leader>= is for. The timeout only costs
-- anything when it actually fires.
local FORMAT_TIMEOUT_MS = 10000

local EXPLODE_CMD = vim.fn.stdpath("config") .. "/scripts/html-explode.js"

conform.setup({
    formatters_by_ft = {
        markdown = { "prettier" },
        html = { "html_explode" },
        css = { "prettier" },
        javascript = { "prettier" },
        json = { "prettier" },
        yaml = { "prettier" },
        zig = { "zigfmt" },
    },
    formatters = {
        prettier = {
            command = prettier_cmd,
        },
        -- html is exploded rather than merely formatted -- see
        -- scripts/html-explode.js. It is also what :w runs, deliberately: a
        -- gentler html formatter would undo the explosion on the next save,
        -- and this one is idempotent, so the file stays as :HtmlExplode left
        -- it. The cost is that every html buffer gets the exploded look, which
        -- is the right default for reading minified markup and the wrong one
        -- for hand-authoring a page.
        html_explode = {
            command = EXPLODE_CMD,
            stdin = true,
        },
        zigfmt = {
            -- use the Linux-native anyzig build, not `zig` (Windows exe on
            -- $PATH) — see after/plugin/lsp.lua for why the Windows binary
            -- doesn't work with Linux-side tooling
            command = vim.fn.exepath("zig-linux") ~= "" and vim.fn.exepath("zig-linux") or "zig",
        },
    },
    format_on_save = function(bufnr)
        -- Autosave sets this buffer-local flag around its write so that it
        -- never reformats the file out from under the user; only an
        -- explicit :w (or <leader>=) should format.
        if vim.b[bufnr].autosave_in_progress then
            return
        end
        return { timeout_ms = FORMAT_TIMEOUT_MS, lsp_fallback = false }
    end,
})

vim.keymap.set({ "n", "v" }, "<leader>=", function()
    conform.format({ timeout_ms = FORMAT_TIMEOUT_MS, lsp_fallback = false })
end, { desc = "Format file" })

-- Explode only the given lines, by running the formatter on those lines alone.
--
-- conform's own `range` cannot do this: it hands the formatter the WHOLE
-- buffer and filters the resulting hunks, which for a blob pasted into a
-- python (or lua, or log) file means prettier parses the entire file as html
-- and every word in it comes back on its own line. Verified -- it ate the file.
-- Feeding it just the selection is the only way the range form is safe.
--
-- The result is spliced in at column 0; it is not re-indented to match the
-- line it replaced, because an exploded blob spans hundreds of lines and the
-- surrounding syntax (a python string, say) cannot survive that anyway. This
-- is for reading markup you pasted, not for keeping the file compiling.
local function explode_range(bufnr, line1, line2)
    local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
    local tick = vim.b[bufnr].changedtick
    vim.system(
        { EXPLODE_CMD },
        { stdin = table.concat(lines, "\n") .. "\n", text = true },
        vim.schedule_wrap(function(res)
            if not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end
            if res.code ~= 0 then
                local msg = res.stderr ~= "" and vim.trim(res.stderr) or ("exited " .. res.code)
                vim.notify("HtmlExplode: " .. msg, vim.log.levels.ERROR)
                return
            end
            -- The buffer moved while node was running, so the line numbers the
            -- range was taken from no longer mean anything.
            if vim.b[bufnr].changedtick ~= tick then
                vim.notify("HtmlExplode: buffer changed while formatting", vim.log.levels.WARN)
                return
            end
            local out = vim.split((res.stdout:gsub("\n$", "")), "\n")
            vim.api.nvim_buf_set_lines(bufnr, line1 - 1, line2, false, out)
        end)
    )
end

-- Explode the buffer even when it is not an html buffer. A minified document
-- is usually somewhere it was pasted -- a scratch buffer, a string in a source
-- file -- so naming the formatter explicitly is the point: <leader>= would
-- pick a formatter by filetype and there would be none, or the wrong one.
vim.api.nvim_create_user_command("HtmlExplode", function(opts)
    -- -range=-1 distinguishes "no range given" (count == -1) from a real one,
    -- which `-range` alone cannot do -- it defaults to the cursor line and
    -- would silently explode a single line instead of the buffer.
    if opts.count ~= -1 then
        return explode_range(0, opts.line1, opts.line2)
    end
    conform.format({
        formatters = { "html_explode" },
        timeout_ms = FORMAT_TIMEOUT_MS,
        lsp_fallback = false,
    }, function(err)
        if err then
            vim.notify("HtmlExplode: " .. err, vim.log.levels.ERROR)
        end
    end)
end, { range = -1, desc = "Format html, breaking on every element" })
