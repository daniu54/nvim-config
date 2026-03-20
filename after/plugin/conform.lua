local conform = require("conform")

conform.setup({
    formatters_by_ft = {
        markdown = { "prettier" },
    },
    formatters = {
        prettier = {
            command = vim.fn.expand("~/.npm-global/bin/prettier"),
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
