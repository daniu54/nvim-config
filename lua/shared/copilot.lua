-- Shared infrastructure for GitHub Copilot inline completion (typeahead).
-- See after/plugin/copilot.lua for the opt-in keymap/command and
-- after/plugin/copilot_chat.lua for the region-refactor feature built on top
-- of the same bootstrap. Read the "AI completion (Copilot)" section in
-- ../../CLAUDE.md first for the overall approach.
--
-- This file used to be two files (lua/shared/ai_completion.lua +
-- lua/shared/copilot_ai.lua) shared between a Claude engine (minuet-ai.nvim)
-- and Copilot. Claude was removed (never used day-to-day — needed paid
-- Anthropic API credits, unlike Copilot which is free via the Student Dev
-- Pack) so this collapsed into one Copilot-only module.
local M = {}

-- Buffer names never sent to Copilot as completion/chat context, regardless
-- of directory opt-in. Extend for anything else you keep in plaintext.
M.sensitive_patterns = {
    '%.env$', '%.env%.', 'secret', 'credential', 'id_rsa', 'id_ed25519',
    '%.pem$', '%.key$', '%.p12$', '%.pfx$', '%.kdbx$', '%.netrc$', '_history$',
    '%.zshrc%.secrets$', '%.zshrc%.bitwarden$',
}

function M.is_sensitive(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr):lower()
    for _, pattern in ipairs(M.sensitive_patterns) do
        if name:match(pattern) then
            return true
        end
    end
    return false
end

-- require('copilot').setup() starts the copilot-language-server Node process
-- immediately, even for filetypes it will never attach to — so it must NOT
-- run at nvim startup, only once a project actually opts in (<leader>la),
-- otherwise every nvim instance pays that cost regardless of the "no AI by
-- default" design.
local ready = false

local function nvm_node()
    local candidates = vim.fn.glob(vim.fn.expand('~/.nvm/versions/node/*/bin/node'), false, true)
    table.sort(candidates)
    return candidates[#candidates] -- highest-sorted installed version
end

function M.ensure_ready()
    if ready then
        return
    end
    ready = true

    require('copilot').setup({
        copilot_node_command = nvm_node(),
        -- filetypes stays maximally restrictive even post-setup: attaching
        -- still only happens via the explicit force-attach call in
        -- after/plugin/copilot.lua's opt-in autocmd, never automatically.
        filetypes = { ['*'] = false },
        suggestion = {
            auto_trigger = false, -- opt-in only
            keymap = {
                accept      = '<A-a>',
                accept_line = '<A-l>',
                next        = '<A-]>',
                prev        = '<A-[>',
                dismiss     = '<A-e>',
            },
        },
        panel = { enabled = false }, -- ghost-text only
    })
end

-- Finds/creates a project's `.nvim.lua`, appends `block_lines` under `marker`
-- (a unique comment, used both as a dedup key and as the autocmd group name so
-- re-running this is idempotent instead of stacking duplicate autocmds), then
-- trusts and immediately sources the file so the change applies to the running
-- session too, not just future nvim launches from that directory.
--
-- If a block for this marker already exists but its content has drifted from
-- `block_lines` (e.g. a module referenced inside it got renamed in a later
-- refactor — this bit us once: lua/shared/ai_completion.lua became
-- lua/shared/copilot.lua and every project's already-written .nvim.lua kept
-- calling require('shared.ai_completion'), erroring on every matching
-- FileType), the stale block is replaced in place rather than left broken.
--
-- Returns the project root path.
function M.enable_project_wide(marker, block_lines)
    local git_dir = vim.fs.find('.git', {
        upward = true,
        path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
    })[1]
    local root = git_dir and vim.fs.dirname(git_dir) or vim.uv.cwd()
    local path = root .. '/.nvim.lua'

    local lines = {}
    if vim.fn.filereadable(path) == 1 then
        lines = vim.fn.readfile(path)
    end

    local marker_idx = nil
    for i, line in ipairs(lines) do
        if line:find(marker, 1, true) then
            marker_idx = i
            break
        end
    end

    local changed = false

    if marker_idx then
        -- The block written under a marker is always the contiguous run of
        -- lines right after it, up to the next blank line (enable_project_wide
        -- always separates entries with a blank line) or end of file.
        local block_end = marker_idx
        while lines[block_end + 1] and lines[block_end + 1] ~= '' do
            block_end = block_end + 1
        end
        local current_block = vim.list_slice(lines, marker_idx + 1, block_end)
        if not vim.deep_equal(current_block, block_lines) then
            local new_lines = vim.list_slice(lines, 1, marker_idx)
            vim.list_extend(new_lines, block_lines)
            vim.list_extend(new_lines, vim.list_slice(lines, block_end + 1, #lines))
            lines = new_lines
            changed = true
            vim.notify('Refreshed stale AI-completion block in ' .. path, vim.log.levels.WARN)
        end
    else
        if #lines == 0 then
            table.insert(lines, '-- Opts this project into AI completion.')
            table.insert(lines, '-- Do NOT commit this file to the project\'s own repo — add ".nvim.lua" to .gitignore.')
        end
        table.insert(lines, '')
        table.insert(lines, marker)
        for _, line in ipairs(block_lines) do
            table.insert(lines, line)
        end
        changed = true
        vim.notify('Updated ' .. path .. ' — remember ".nvim.lua" is in .gitignore', vim.log.levels.WARN)
    end

    if changed then
        vim.fn.writefile(lines, path)
    end

    -- vim.secure.trust with action='allow' hashes a buffer's live content, not
    -- the file on disk, so load it into a scratch buffer just to compute/store
    -- the hash (this also means future launches skip the exrc trust prompt).
    --
    -- bufload() sets filetype on that scratch buffer, which fires FileType —
    -- and since the block we just wrote registers a `pattern = '*'` FileType
    -- autocmd, loading .nvim.lua would otherwise immediately re-trigger
    -- Copilot's own attach logic against whatever buffer happens to be
    -- current. eventignore suppresses that.
    local saved_eventignore = vim.o.eventignore
    vim.o.eventignore = 'FileType'
    local trust_buf = vim.fn.bufadd(path)
    vim.fn.bufload(trust_buf)
    vim.o.eventignore = saved_eventignore
    vim.secure.trust({ action = 'allow', bufnr = trust_buf })
    vim.api.nvim_buf_delete(trust_buf, { force = true })

    vim.cmd('luafile ' .. vim.fn.fnameescape(path))

    return root
end

local function copilot_suggestion()
    local ok, suggestion = pcall(require, 'copilot.suggestion')
    return ok and suggestion or nil
end

-- <Right> / <S-Right>: accept / request a Copilot suggestion. Bound globally
-- and once here, rather than through copilot.lua's own `keymap` config table,
-- because unlike the Alt-key bindings (dead keys when idle, so a silent no-op
-- is harmless), <Right> is real cursor movement — accepting must fall through
-- to a normal right-arrow press when no ghost text is shown, or every idle
-- keystroke in insert mode would eat the movement.
vim.keymap.set('i', '<Right>', function()
    local copilot = copilot_suggestion()
    if copilot and copilot.is_visible() then
        copilot.accept()
        return
    end

    -- no suggestion: behave like a plain right-arrow.
    -- 'n' (noremap) so this doesn't loop back into this same mapping.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Right>', true, false, true), 'n', true)
end, { desc = 'Accept Copilot suggestion, else move cursor right' })

vim.keymap.set('i', '<S-Right>', function()
    local copilot = copilot_suggestion()
    if copilot then
        pcall(copilot.next)
    end
end, { desc = 'Request/cycle a Copilot suggestion' })

return M
