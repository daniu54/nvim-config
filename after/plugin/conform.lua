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
        -- Exploding is a mode a buffer is put into by :HtmlExplode, not the
        -- default. Ordinary html formats the ordinary way; a buffer that was
        -- explicitly exploded keeps being exploded by :w and <leader>=, which
        -- is the only way the explosion survives a save -- a gentler formatter
        -- would put it straight back together.
        html = function(bufnr)
            return vim.b[bufnr].html_exploded and { "html_explode" } or { "prettier" }
        end,
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
        -- Breaks html on every element -- see scripts/html-explode.js. Only
        -- reached through :HtmlExplode, or on a buffer it has been run on.
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
        -- A buffer whose exact line shape is load-bearing opts out entirely --
        -- :GitReview's document is parsed back on the next run to recover the
        -- review boxes and comments in it, and prettier reflows markdown.
        if vim.b[bufnr].no_autoformat then
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
--
-- Succeeding puts the buffer into exploded mode, so a later :w or <leader>=
-- keeps it exploded instead of quietly reassembling it. :HtmlExplode! leaves
-- that mode and formats the buffer the ordinary way. The mode is buffer-local
-- and so does not survive closing the file -- reopening an exploded file gives
-- an ordinary html buffer, and saving it then reformats it normally.
--
-- A range does NOT set the mode: it is a surgical edit on a fragment, usually
-- in a buffer that is not html at all, and putting the whole buffer into
-- exploded mode on the strength of it would reformat everything else too.
vim.api.nvim_create_user_command("HtmlExplode", function(opts)
    local bufnr = vim.api.nvim_get_current_buf()

    if opts.bang then
        vim.b[bufnr].html_exploded = nil
        conform.format({ timeout_ms = FORMAT_TIMEOUT_MS, lsp_fallback = false }, function(err)
            if err then
                vim.notify("HtmlExplode: " .. err, vim.log.levels.ERROR)
            end
        end)
        return
    end

    -- -range=-1 distinguishes "no range given" (count == -1) from a real one,
    -- which `-range` alone cannot do -- it defaults to the cursor line and
    -- would silently explode a single line instead of the buffer.
    if opts.count ~= -1 then
        return explode_range(bufnr, opts.line1, opts.line2)
    end

    conform.format({
        formatters = { "html_explode" },
        timeout_ms = FORMAT_TIMEOUT_MS,
        lsp_fallback = false,
    }, function(err)
        if err then
            vim.notify("HtmlExplode: " .. err, vim.log.levels.ERROR)
            return
        end
        vim.b[bufnr].html_exploded = true
    end)
end, { range = -1, bang = true, desc = "Format html, breaking on every element" })
