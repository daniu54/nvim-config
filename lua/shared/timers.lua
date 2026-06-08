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
                local label = f:read("l") or name
                f:close()
                if end_epoch then
                    table.insert(timers, {
                        id = name,
                        label = label,
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
    if secs <= 0 then return "DONE" end
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

local function build_statusline()
    local timers = read_timers()
    local parts = {}
    for _, t in ipairs(timers) do
        local rem = fmt_remaining(t.remaining)
        local urgent = t.remaining <= 60
        local hl = urgent and "%#TimerUrgent#" or "%#TimerNormal#"
        table.insert(parts, hl .. " ⏱ " .. t.label .. " " .. rem .. " %*")
    end
    local timer_str = table.concat(parts, "")
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
