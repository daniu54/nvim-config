local cmp = require('cmp')

-- Counts how often each word appears in the current buffer.
-- Result is cached by changedtick so it only recounts on actual edits.
local buf_freq_cache = {}
local buf_freq_tick  = {}

local function buf_word_counts()
    local bufnr = vim.api.nvim_get_current_buf()
    local tick  = vim.api.nvim_buf_get_changedtick(bufnr)
    if buf_freq_tick[bufnr] == tick then
        return buf_freq_cache[bufnr]
    end
    local counts = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        for word in line:gmatch('%a+') do
            counts[word] = (counts[word] or 0) + 1
        end
    end
    buf_freq_cache[bufnr] = counts
    buf_freq_tick[bufnr]  = tick
    return counts
end

local function frequency_comparator(entry1, entry2)
    local counts = buf_word_counts()
    local c1 = counts[entry1.completion_item.label] or 0
    local c2 = counts[entry2.completion_item.label] or 0
    if c1 ~= c2 then return c1 > c2 end
end

cmp.setup({
    sorting = {
        comparators = {
            frequency_comparator,                   -- words that appear most in buffer rank first
            cmp.config.compare.recently_used,       -- then words you confirmed recently
            cmp.config.compare.offset,
            cmp.config.compare.exact,
            cmp.config.compare.score,
            cmp.config.compare.kind,
            cmp.config.compare.length,
        },
    },

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
        -- <C-p> is reserved for the telescope yank-history picker (telescope.lua)
        ['<C-p>']     = cmp.mapping(function(fallback) fallback() end, { 'i' }),
    }),

    sources = cmp.config.sources(
        {
            { name = 'nvim_lsp' },   -- active only when LSP is attached (see :LspEnable)
        },
        {
            { name = 'buffer', keyword_length = 1 },  -- words from open buffers
            { name = 'path' },                         -- file paths
        }
    ),
})
