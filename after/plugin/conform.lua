local conform = require("conform")

conform.setup({
    formatters_by_ft = {
        markdown = { "prettier" },
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
    format_on_save = {
        timeout_ms = 2000,
        lsp_fallback = false,
    },
})

vim.keymap.set({ "n", "v" }, "<leader>=", function()
    conform.format({ timeout_ms = 2000, lsp_fallback = false })
end, { desc = "Format file" })
