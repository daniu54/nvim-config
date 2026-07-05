local M = {}

local TIMER_DIR = vim.fn.expand("~/.local/share/timers")
local _tick = nil

local function read_timers()
    local timers = {}
    local now = os.time()
    local uv = vim.uv or vim.loop
    local handle = uv.fs_scandir(TIMER_DIR)
    if not handle then return timers end
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        if ftype == "file" and not name:match("^%.") then
            local f = io.open(TIMER_DIR .. "/" .. name, "r")
            if f then
                local end_epoch = tonumber(f:read("l"))
                local label = f:read("l") or ""
                local comment = f:read("l") or ""
                f:close()
                if end_epoch then
                    table.insert(timers, {
                        id = name,
                        label = label,
                        comment = comment,
                        remaining = end_epoch - now,
                        end_epoch = end_epoch,
                    })
                end
            end
        end
    end
    table.sort(timers, function(a, b) return a.end_epoch < b.end_epoch end)
    return timers
end

local function fmt_remaining(secs)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = math.floor(secs % 60)
    if h > 0 then
        return string.format("%dh%02dm%02ds", h, m, s)
    elseif m > 0 then
        return string.format("%dm%02ds", m, s)
    else
        return string.format("%ds", s)
    end
end

local function fmt_overdue(secs)
    local abs = -secs
    local h = math.floor(abs / 3600)
    local m = math.floor((abs % 3600) / 60)
    if h > 0 then
        return string.format("-%dh%02dm", h, m)
    elseif m > 0 then
        return string.format("-%dm", m)
    else
        return string.format("-%ds", abs)
    end
end

local function display_len(s)
    return vim.fn.strdisplaywidth(s:gsub("%%#[^#]*#", ""):gsub("%%%*", ""))
end

local function build_timer_parts(timers, include_comment)
    local parts = {}
    for _, t in ipairs(timers) do
        local rem
        if t.remaining <= 0 then
            rem = t.label .. "/" .. fmt_overdue(t.remaining)
        else
            rem = fmt_remaining(t.remaining)
        end
        local urgent = t.remaining <= 60
        local hl = urgent and "%#TimerUrgent#" or "%#TimerNormal#"
        local suffix = (include_comment and t.comment ~= "") and (" " .. t.comment) or ""
        table.insert(parts, hl .. " ⏱ " .. rem .. suffix .. " %*")
    end
    return table.concat(parts, " │ ")
end

local function build_statusline()
    local timers = read_timers()
    local timer_str = ""

    if #timers > 0 then
        -- 30 chars reserved for " filename [+]  42:10 "
        local available = vim.o.columns - 30
        local full = build_timer_parts(timers, true)
        timer_str = display_len(full) <= available and full or build_timer_parts(timers, false)
    end

    return " %f %m%=" .. timer_str .. " %l:%c "
end

function M.setup()
    vim.api.nvim_set_hl(0, "TimerNormal", { fg = "#7dcfff", bold = true })
    vim.api.nvim_set_hl(0, "TimerUrgent", { fg = "#f7768e", bold = true, reverse = true })

    vim.opt.statusline = build_statusline()

    local uv = vim.uv or vim.loop
    _tick = uv.new_timer()
    _tick:start(0, 1000, vim.schedule_wrap(function()
        vim.opt.statusline = build_statusline()
    end))
end

return M
