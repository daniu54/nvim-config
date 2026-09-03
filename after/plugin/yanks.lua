-- :Yanks -- the whole yank history as an ordinary buffer, and the only way in.
--
-- Over `lua/shared/yank_store.lua`: a file-backed log every running nvim
-- appends to and re-reads, so this is one global history -- the outer terminal
-- nvim, an inner nvim in a tmux pane, another window entirely.
--
-- It is a real buffer, so `/`, visual mode, `yy` and every other motion work on
-- it -- which is the entire point, and why it is rendered as the entries' text
-- verbatim with headers in between rather than as one-line summaries. Reading
-- the history, comparing two entries and taking three lines out of the middle
-- of one all work here and in a fuzzy-finder do not; that is why the telescope
-- picker this used to have alongside it is gone, and <C-p> opens this instead.
--
-- Opened with :Yanks, or :Yanks! for a vsplit on the right instead of a split
-- below (a history of long lines reads better in a tall narrow window).

local store = require('shared.yank_store')

local ns = vim.api.nvim_create_namespace('yanks')

-- The one buffer, reused. A second :Yanks refreshes it rather than stacking up
-- windows onto stale copies of a history that changes under them.
--
-- `origin` is the window :Yanks was called from -- what <CR> pastes into. Its
-- mode is remembered too, because pasting back into it has to end where the
-- key was pressed: a terminal wants the text written to the shell's stdin and
-- insert mode resumed, an insert-mode paste wants insert mode back.
local state = { buf = nil, origin = nil, job = nil, insert = false, entries = {} }

local REGTYPE = { c = 'charwise', l = 'linewise', b = 'blockwise' }

local function render()
    local yanks = store.get() -- most recent first; re-read if the file changed
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
-- paste into and the caller's fallback runs instead.
local function with_origin(fn, fallback)
    local win = state.origin
    vim.cmd('close')
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        fn()
    elseif fallback then
        fallback()
    end
end

-- <CR> and p/P all end here. The unnamed register is loaded first with the
-- entry's own regtype, so the paste behaves like the original yank did (a
-- linewise entry lands on its own lines) and a following `p` repeats it.
local function paste(entry, after)
    vim.fn.setreg('"', entry.contents, entry.regtype)
    local job, insert = state.job, state.insert
    with_origin(function()
        if job then
            -- A terminal: text goes to the shell's stdin, not into the buffer.
            vim.api.nvim_chan_send(job, table.concat(entry.contents, '\n'))
            -- Scheduled: the window switch this is inside of has to land first,
            -- or the mode is set on the window we are leaving.
            vim.schedule(function() vim.cmd('startinsert') end)
        else
            vim.api.nvim_put(entry.contents, entry.regtype, after, true)
            if insert then vim.api.nvim_feedkeys('a', 'n', false) end
        end
    end, function()
        vim.notify(('Yanks: %d line(s) in the unnamed register'):format(#entry.contents))
    end)
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

    local function pick(after)
        return function()
            local entry = entry_at_cursor()
            if not entry then return end
            paste(entry, after)
        end
    end

    map('<CR>', pick(true), 'Yanks: paste entry into the origin window, close')
    map('p', pick(true), 'Yanks: paste entry after cursor in the origin window')
    map('P', pick(false), 'Yanks: paste entry before cursor in the origin window')

    -- Deletes from the shared store, so it is gone from every nvim.
    map('d', function()
        local entry = entry_at_cursor()
        if not entry then return end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        store.delete(entry)
        render()
        pcall(vim.api.nvim_win_set_cursor, 0, { math.min(row, vim.api.nvim_buf_line_count(0)), 0 })
    end, 'Yanks: delete entry from the history')

    map('R', render, 'Yanks: refresh')
end

--- opts: vertical (vsplit), insert (return to insert mode after pasting),
--- job (a terminal's channel: paste writes to the shell instead of the buffer).
local function open(opts)
    opts = opts or {}
    state.origin = vim.api.nvim_get_current_win()
    state.insert = opts.insert or false
    state.job = opts.job

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

    vim.cmd(opts.vertical and 'botright vsplit' or 'botright split')
    vim.api.nvim_win_set_buf(0, state.buf)
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.wrap = false
    vim.wo.cursorline = true

    render()

    if not opts.vertical then
        vim.api.nvim_win_set_height(0, math.min(20, math.max(10, vim.api.nvim_buf_line_count(0) + 1)))
    end
    -- Land on the newest entry's first line, not on its header.
    pcall(vim.api.nvim_win_set_cursor, 0, { math.min(2, vim.api.nvim_buf_line_count(0)), 0 })
end

vim.api.nvim_create_user_command('Yanks', function(opts)
    open({ vertical = opts.bang })
end, { bang = true, desc = 'Yank history as a buffer (! = vsplit)' })

-- <C-p> is the key for this, in normal, insert and terminal mode (it overrides
-- nvim's builtin <C-p> = move up / previous completion). It used to open a
-- telescope picker over the same history; the buffer won.
vim.keymap.set({ 'n', 'i' }, '<C-p>', function()
    local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == 'i'
    if insert then vim.cmd('stopinsert') end
    -- From insert mode, let stopinsert land before the split opens.
    vim.schedule(function() open({ insert = insert }) end)
end, { desc = 'Yank history (:Yanks)' })

vim.keymap.set('t', '<C-p>', function()
    local job = vim.b.terminal_job_id
    -- Out of terminal mode first, the same way <C-e> (scrollback) does it:
    -- a window opened from inside terminal mode leaves the mode behind.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>', true, false, true), 'n', false)
    vim.schedule(function() open({ job = job }) end)
end, { desc = 'Yank history (:Yanks) → paste into the shell' })
