local M = {}

local TIMER_DIR = vim.fn.expand("~/.local/share/timers")
local _tick = nil

-- Thresholds (seconds of time left) driving colour and abbreviation.
local URGENT_THRESHOLD = 5 * 60  -- red below this
local WARN_THRESHOLD = 15 * 60   -- yellow below this; seconds shown below this
local COARSE_THRESHOLD = 2 * 3600 -- above this, drop minutes too

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

-- Precision follows urgency: seconds only in the last 15 minutes, minutes
-- only under 2 hours, hours alone above that.
local function fmt_remaining(secs)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = math.floor(secs % 60)
    if secs > COARSE_THRESHOLD then
        return string.format("%dh", h)
    elseif secs > WARN_THRESHOLD then
        if h > 0 then
            return string.format("%dh%02dm", h, m)
        end
        return string.format("%dm", m)
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

local function timer_hl(remaining)
    if remaining <= URGENT_THRESHOLD then
        return "%#TimerUrgent#"
    elseif remaining <= WARN_THRESHOLD then
        return "%#TimerWarn#"
    end
    return "%#TimerNormal#"
end

local function display_len(s)
    return vim.fn.strdisplaywidth(s:gsub("%%#[^#]*#", ""):gsub("%%%*", ""))
end

local function build_timer_parts(timers, include_comment)
    local parts = {}
    for i, t in ipairs(timers) do
        local rem
        if t.remaining <= 0 then
            rem = t.label .. "/" .. fmt_overdue(t.remaining)
        else
            rem = fmt_remaining(t.remaining)
        end
        -- Only the next timer to fire is named; the rest are just countdowns.
        local suffix = ""
        if include_comment and i == 1 and t.comment ~= "" then
            suffix = " " .. t.comment
        end
        table.insert(parts, timer_hl(t.remaining) .. " " .. rem .. suffix .. " %*")
    end
    return table.concat(parts, " │ ")
end

local function build_statusline()
    local timers = read_timers()
    local timer_str = ""

    if #timers > 0 then
        -- 36 chars reserved for " filename [+]  42:10 (99%) "
        local available = vim.o.columns - 36
        local full = build_timer_parts(timers, true)
        timer_str = display_len(full) <= available and full or build_timer_parts(timers, false)
    end

    -- %p is the cursor line as a percentage of the file's line count, so the
    -- ratio doubles as a sense of how long the file is.
    return " %f %m%=" .. timer_str .. " %l:%c (%p%%) "
end

function M.setup()
    vim.api.nvim_set_hl(0, "TimerNormal", { fg = "#7dcfff", bold = true })
    vim.api.nvim_set_hl(0, "TimerWarn", { fg = "#e0af68", bold = true })
    vim.api.nvim_set_hl(0, "TimerUrgent", { fg = "#f7768e", bold = true, reverse = true })

    vim.opt.statusline = build_statusline()

    local uv = vim.uv or vim.loop
    _tick = uv.new_timer()
    _tick:start(0, 1000, vim.schedule_wrap(function()
        vim.opt.statusline = build_statusline()
    end))
end

return M
