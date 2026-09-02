-- :Yanks — the whole yank history as an ordinary buffer.
--
-- The sibling of the <C-p> telescope picker (after/plugin/telescope.lua), over
-- exactly the same store: neoclip's sqlite-backed history, which with
-- `continuous_sync` (lua/shared/lazy.lua) is one global history shared live by
-- every running nvim — the outer terminal nvim, an inner nvim in a tmux pane,
-- another window entirely.
--
-- The picker is for "I know roughly what I want, let me fuzzy-find it". This is
-- for the other half: reading the history, comparing two entries, taking three
-- lines out of the middle of one. It is a real buffer, so `/`, visual mode, `yy`
-- and every other motion work on it — which is the entire point, and why it is
-- rendered as the entries' text verbatim with headers in between rather than as
-- one-line summaries.
--
-- Opened with :Yanks, or :Yanks! for a vsplit on the right instead of a split
-- below (a history of long lines reads better in a tall narrow window).

local ok_storage, storage = pcall(require, 'neoclip.storage')
if not ok_storage then return end

local ns = vim.api.nvim_create_namespace('yanks')

-- The one buffer, reused. A second :Yanks refreshes it rather than stacking up
-- windows onto stale copies of a history that changes under them.
local state = { buf = nil, origin = nil, entries = {} }

local REGTYPE = { c = 'charwise', l = 'linewise', b = 'blockwise' }

local function render()
    local yanks = storage.get().yanks -- most recent first; pulls from the db
    local lines, marks, index = {}, {}, {}

    if #yanks == 0 then
        lines = { '(yank history is empty)' }
    end

    for i, entry in ipairs(yanks) do
        local parts = { tostring(i) }
        if entry.filetype and entry.filetype ~= '' then table.insert(parts, entry.filetype) end
        table.insert(parts, REGTYPE[entry.regtype] or entry.regtype)
        local header = ('── %s ──'):format(table.concat(parts, ' · '))

        table.insert(lines, header)
        table.insert(marks, #lines - 1)
        for _, l in ipairs(entry.contents) do
            table.insert(lines, l)
            -- Which entry each line belongs to, so the cursor identifies one.
            index[#lines] = entry
        end
        index[#lines - #entry.contents] = entry -- the header line too
    end

    state.entries = index

    local buf = state.buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, row in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #lines[row + 1], hl_group = 'Title' })
    end
end

local function entry_at_cursor()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    -- A cursor between entries (never happens as rendered, but be safe) walks
    -- back to the entry it is inside.
    for r = row, 1, -1 do
        if state.entries[r] then return state.entries[r] end
    end
end

-- Leave the list and act on the window :Yanks was called from. That window may
-- be gone (closed while the list was open), in which case there is nothing to
-- paste into and the entry is left in the register.
local function with_origin(fn)
    local win = state.origin
    vim.cmd('close')
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        fn()
    end
end

local function setup_buf(buf)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].filetype = 'yanks'
    vim.api.nvim_buf_set_name(buf, 'yanks://history')

    local function map(lhs, fn, desc)
        vim.keymap.set('n', lhs, fn, { buffer = buf, desc = desc })
    end

    map('q', '<cmd>close<CR>', 'Yanks: close')

    -- <CR>: load the entry into the unnamed register with its own regtype, so
    -- the `p` that follows behaves like the original yank did (a linewise entry
    -- pastes on its own lines).
    map('<CR>', function()
        local entry = entry_at_cursor()
        if not entry then return end
        vim.fn.setreg('"', entry.contents, entry.regtype)
        vim.cmd('close')
        vim.notify(('Yanks: %d line(s) in the unnamed register'):format(#entry.contents))
    end, 'Yanks: entry -> unnamed register, close')

    map('p', function()
        local entry = entry_at_cursor()
        if not entry then return end
        with_origin(function() vim.api.nvim_put(entry.contents, entry.regtype, true, true) end)
    end, 'Yanks: paste entry after cursor in the origin window')

    map('P', function()
        local entry = entry_at_cursor()
        if not entry then return end
        with_origin(function() vim.api.nvim_put(entry.contents, entry.regtype, false, true) end)
    end, 'Yanks: paste entry before cursor in the origin window')

    -- Deletes from the shared store, so it is gone from every nvim.
    map('d', function()
        local entry = entry_at_cursor()
        if not entry then return end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        storage.delete('yanks', entry)
        render()
        pcall(vim.api.nvim_win_set_cursor, 0, { math.min(row, vim.api.nvim_buf_line_count(0)), 0 })
    end, 'Yanks: delete entry from the history')

    map('R', render, 'Yanks: refresh')
end

local function open(vertical)
    state.origin = vim.api.nvim_get_current_win()

    if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
        state.buf = vim.api.nvim_create_buf(false, true)
        setup_buf(state.buf)
    end

    -- Already on screen: refresh it in place rather than opening a second window
    -- onto the same buffer.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == state.buf then
            vim.api.nvim_set_current_win(win)
            render()
            return
        end
    end

    vim.cmd(vertical and 'botright vsplit' or 'botright split')
    vim.api.nvim_win_set_buf(0, state.buf)
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.wrap = false
    vim.wo.cursorline = true

    render()

    if not vertical then
        vim.api.nvim_win_set_height(0, math.min(20, math.max(10, vim.api.nvim_buf_line_count(0) + 1)))
    end
    -- Land on the newest entry's first line, not on its header.
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(2, vim.api.nvim_buf_line_count(0)), 0 })
end

vim.api.nvim_create_user_command('Yanks', function(opts)
    open(opts.bang)
end, { bang = true, desc = 'Yank history as a buffer (! = vsplit)' })
