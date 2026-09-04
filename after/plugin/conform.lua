local conform = require("conform")

local prettier_cmd = vim.fn.expand("~/.npm-global/bin/prettier")

conform.setup({
    formatters_by_ft = {
        markdown = { "prettier" },
        html = { "prettier_html" },
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
        -- html only. `--html-whitespace-sensitivity ignore` is what actually
        -- breaks up a minified one-line document: prettier's default ("css")
        -- keeps inline elements (<b>, <span>, <a>) glued to the text around
        -- them, because inserting a newline there changes what the browser
        -- renders. `ignore` drops that guarantee and puts every element on its
        -- own line — the right trade for reading a blob, wrong for prose-heavy
        -- markup where the added/removed spaces are visible.
        prettier_html = {
            command = prettier_cmd,
            args = { "--html-whitespace-sensitivity", "ignore", "--stdin-filepath", "$FILENAME" },
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
        return { timeout_ms = 5000, lsp_fallback = false }
    end,
})

-- 10s, not the 2s this used to be: prettier takes ~2s on a 400KB minified
-- html file, and unminifying one is exactly what this keymap is for. The
-- timeout only costs anything when it fires.
vim.keymap.set({ "n", "v" }, "<leader>=", function()
    conform.format({ timeout_ms = 10000, lsp_fallback = false })
end, { desc = "Format file" })
