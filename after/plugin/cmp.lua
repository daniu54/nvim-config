local cmp = require('cmp')

cmp.setup({
    snippet = {
        expand = function(args)
            require('luasnip').lsp_expand(args.body)
        end,
    },

    mapping = cmp.mapping.preset.insert({
        -- Tab/S-Tab: navigate menu when open, otherwise insert a real tab
        ['<Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
                cmp.select_next_item()
            else
                fallback()
            end
        end, { 'i', 's' }),
        ['<S-Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
                cmp.select_prev_item()
            else
                fallback()
            end
        end, { 'i', 's' }),

        ['<CR>']      = cmp.mapping.confirm({ select = false }),  -- confirm only if explicitly selected
        ['<C-e>']     = cmp.mapping.abort(),                      -- close menu
        ['<C-Space>'] = cmp.mapping.complete(),                   -- manually trigger
    }),

    sources = cmp.config.sources(
        {
            { name = 'nvim_lsp' },   -- active only when LSP is attached (see :LspEnable)
        },
        {
            { name = 'buffer', keyword_length = 2 },  -- words from open buffers
            { name = 'path' },                         -- file paths
        }
    ),
})
