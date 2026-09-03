-- The yank history: one global store, shared live by every running nvim.
--
-- This replaces neoclip + sqlite.lua, which were removed. neoclip's store is a
-- sqlite table and its `continuous_sync` push is a *delete-all + reinsert-all of
-- the whole table on every yank* -- and every `dd`, `x` and `cw` is a yank. At
-- the 200-entry history that config ran, that is 200 rows rewritten through a
-- C extension before the cursor moves, and it was felt as lag while editing.
--
-- The shape here follows from that, and from the priorities: writing must be
-- fast, then pasting the most recent entry, then reading the whole history.
--
--   * The file is an **append-only JSON-lines log**. Recording a yank is one
--     `open(O_APPEND)` + one `write` + one `close` of a few hundred bytes --
--     the cost does not grow with the history, which is the whole point.
--   * It is **read** by parsing the file, newest-first, keeping the newest
--     MAX entries and skipping duplicates. Reads are rare (opening :Yanks)
--     and the file is small, so paying there to keep writes cheap is the
--     right trade.
--   * A **compaction** rewrites the file down to those MAX entries once it
--     grows past COMPACT_BYTES, via a temp file and a rename, so the log
--     cannot grow without bound. The rename is atomic, so a reader never sees
--     a half-written history; entries appended by *another* nvim between the
--     read and the rename are lost, which is the one race here and is worth
--     the simplicity at this scale.
--
-- Every instance appends to and re-reads the same file, so the history is
-- shared live between concurrently running nvims (the outer terminal nvim, an
-- inner one in a tmux pane, another window entirely) -- what `continuous_sync`
-- bought, without the write cost. A truncated last line (a crash mid-write) is
-- skipped by the reader rather than poisoning the file: one entry per line is
-- also what makes that true.

local M = {}

-- The history cap. Small on purpose: this is "the last few things I yanked",
-- not an archive, and a short list is one screenful in :Yanks.
M.MAX = 15

-- A single entry bigger than this is not recorded. A yank that large is a file,
-- not a clipboard entry, and MAX of them would be the whole store.
local MAX_ENTRY_BYTES = 1024 * 1024

-- Compact once the log passes this. It bounds the file, and so the read.
local COMPACT_BYTES = 128 * 1024

local path = vim.fn.stdpath('data') .. '/yanks.jsonl'

-- vim's regtype ('v' / 'V' / '\022<width>') as one character.
local function regtype_of(rt)
    local c = rt:sub(1, 1)
    if c == 'V' then return 'l' end
    if c == '\22' then return 'b' end
    return 'c'
end

local cache = { entries = nil, size = nil, mtime = nil }

local function key_of(entry)
    return entry.regtype .. '\0' .. table.concat(entry.contents, '\n')
end

-- Newest-first, deduplicated, at most MAX. Walks the log backwards so the most
-- recent copy of a repeated yank is the one that survives, and so the loop can
-- stop as soon as it has MAX of them.
local function parse(lines)
    local entries, seen = {}, {}
    for i = #lines, 1, -1 do
        local ok, entry = pcall(vim.json.decode, lines[i])
        if ok and type(entry) == 'table' and type(entry.contents) == 'table' and #entry.contents > 0 then
            entry.regtype = entry.regtype or 'c'
            local k = key_of(entry)
            if not seen[k] then
                seen[k] = true
                entries[#entries + 1] = entry
                if #entries >= M.MAX then break end
            end
        end
    end
    return entries
end

local function read_file()
    local fd = io.open(path, 'r')
    if not fd then return {} end
    local data = fd:read('*a')
    fd:close()
    return vim.split(data, '\n', { plain = true, trimempty = true })
end

-- Rewrite the log as exactly the entries a reader would have seen. Written to a
-- sibling temp file and renamed, so the swap is atomic for everyone else.
local function compact(entries)
    local tmp = path .. '.' .. vim.fn.getpid() .. '.tmp'
    local fd = io.open(tmp, 'w')
    if not fd then return end
    -- Oldest first: the file is a log, and the reader walks it backwards.
    for i = #entries, 1, -1 do
        fd:write(vim.json.encode(entries[i]), '\n')
    end
    fd:close()
    if not os.rename(tmp, path) then os.remove(tmp) end
    cache.entries = nil
end

--- The history, newest first. Each entry is { contents = {lines}, regtype =
--- 'c'|'l'|'b', filetype = string }.
function M.get()
    local st = vim.uv.fs_stat(path)
    if not st then
        cache = { entries = {}, size = nil, mtime = nil }
        return {}
    end
    -- Another nvim's append changes size *and* mtime; ours does too. Comparing
    -- both against the last read is what makes a stale cache impossible.
    local mtime = st.mtime.sec * 1e9 + st.mtime.nsec
    if cache.entries and cache.size == st.size and cache.mtime == mtime then
        return cache.entries
    end
    local entries = parse(read_file())
    cache = { entries = entries, size = st.size, mtime = mtime }
    return entries
end

--- Append one entry. The hot path: called on every yank and every delete.
function M.record(contents, regtype, filetype)
    if #contents == 0 or (#contents == 1 and contents[1] == '') then return end

    local line = vim.json.encode({
        contents = contents,
        regtype = regtype,
        filetype = filetype ~= '' and filetype or nil,
    })
    if #line > MAX_ENTRY_BYTES then return end

    local fd = io.open(path, 'a')
    if not fd then return end
    fd:write(line, '\n')
    local size = fd:seek('end')
    fd:close()

    if size and size > COMPACT_BYTES then compact(M.get()) end
end

--- Remove one entry from the history, everywhere -- this is the shared store.
--- Costs a rewrite, which is why it is only reachable from :Yanks and not from
--- anything that runs while editing.
function M.delete(entry)
    local target = key_of(entry)
    local kept = {}
    for _, e in ipairs(M.get()) do
        if key_of(e) ~= target then kept[#kept + 1] = e end
    end
    compact(kept)
end

--- Empty the history.
function M.clear()
    compact({})
end

function M.setup()
    vim.api.nvim_create_autocmd('TextYankPost', {
        group = vim.api.nvim_create_augroup('YankStore', { clear = true }),
        callback = function()
            local ev = vim.v.event
            -- The black hole is the register you use *to not keep* something.
            if ev.regname == '_' then return end
            M.record(ev.regcontents, regtype_of(ev.regtype), vim.bo.filetype)
        end,
        desc = 'Record the yank in the global yank history',
    })
end

return M
