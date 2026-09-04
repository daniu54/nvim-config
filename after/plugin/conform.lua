local conform = require("conform")

conform.setup({
    formatters_by_ft = {
        markdown = { "prettier" },
        html = { "prettier" },
        zig = { "zigfmt" },
    },
    formatters = {
        prettier = {
            command = vim.fn.expand("~/.npm-global/bin/prettier"),
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
        return { timeout_ms = 2000, lsp_fallback = false }
    end,
})

vim.keymap.set({ "n", "v" }, "<leader>=", function()
    conform.format({ timeout_ms = 2000, lsp_fallback = false })
end, { desc = "Format file" })
