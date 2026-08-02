-- csvview.nvim: auto-enable column alignment + sticky header for csv/tsv
-- files, plus a lightweight hover tooltip showing the current column's
-- header name. The sticky header (plugin default) already pins the header
-- row to the top of the window on vertical scroll; this tooltip covers the
-- remaining case of wide files scrolled horizontally, where the header for
-- the column under the cursor may not be visible at all.
local augroup = vim.api.nvim_create_augroup('CsvColumnHover', { clear = true })

local function close_hover(state)
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_win_close(state.winid, true)
    end
    state.winid = nil
end

local function show_column_hover(bufnr, state)
    close_hover(state)

    local ok_enabled, enabled = pcall(require('csvview').is_enabled, bufnr)
    if not ok_enabled or not enabled then return end

    local ok_cursor, cursor = pcall(require('csvview.util').get_cursor, bufnr)
    if not ok_cursor or cursor.kind ~= 'field' then return end

    local view = require('csvview.view').get(bufnr)
    if not view or not view.header_lnum then return end

    -- Don't show a tooltip while sitting on the header row itself.
    local header_row_idx = view.metrics:get_logical_row_idx(view.header_lnum)
    if not header_row_idx or header_row_idx == cursor.pos[1] then return end

    local col_idx = cursor.pos[2]
    local ok_fields, fields = pcall(view.metrics.get_logical_row_fields, view.metrics,
        { lnum = view.header_lnum })
    if not ok_fields or not fields[col_idx] then return end

    local range = fields[col_idx]
    local lines = vim.api.nvim_buf_get_text(
        bufnr, range.start_row - 1, range.start_col, range.end_row - 1, range.end_col, {})
    local header_text = table.concat(lines, ' ')
    if header_text == '' then return end

    local _, winid = vim.lsp.util.open_floating_preview({ header_text }, 'plaintext', {
        focus = false,
        focusable = false,
        border = 'rounded',
        max_width = 60,
        max_height = 1,
    })
    state.winid = winid
end

vim.api.nvim_create_autocmd('FileType', {
    group = augroup,
    pattern = { 'csv', 'tsv' },
    callback = function(args)
        local bufnr = args.buf
        -- FileType can fire more than once for the same buffer (e.g. lazy.nvim
        -- loading the plugin on first csv/tsv file re-triggers detection) —
        -- guard against registering duplicate per-buffer autocmds.
        if vim.b[bufnr].csvview_hover_setup then return end
        vim.b[bufnr].csvview_hover_setup = true

        if not require('csvview').is_enabled(bufnr) then
            require('csvview').enable(bufnr)
        end

        local state = {}

        vim.api.nvim_create_autocmd('CursorHold', {
            group = augroup,
            buffer = bufnr,
            callback = function() show_column_hover(bufnr, state) end,
        })

        vim.api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufLeave' }, {
            group = augroup,
            buffer = bufnr,
            callback = function() close_hover(state) end,
        })
    end,
})
