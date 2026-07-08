-- Shared infrastructure for AI-based inline completion (typeahead) engines
-- (see after/plugin/minuet.lua for Claude, after/plugin/copilot.lua for GitHub
-- Copilot). Both engines are opt-in per project via the same mechanism: a
-- trusted `.nvim.lua` at the project root, sourced via `exrc` (lua/shared/set.lua).
local M = {}

-- Buffer names never sent to any AI completion engine as context, regardless
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

-- Finds/creates a project's `.nvim.lua`, appends `block_lines` under `marker`
-- (a unique comment, used both as a dedup key and as the autocmd group name so
-- re-running this is idempotent instead of stacking duplicate autocmds), then
-- trusts and immediately sources the file so the change applies to the running
-- session too, not just future nvim launches from that directory.
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

    local already_present = false
    for _, line in ipairs(lines) do
        if line:find(marker, 1, true) then
            already_present = true
            break
        end
    end

    if not already_present then
        if #lines == 0 then
            table.insert(lines, '-- Opts this project into AI completion.')
            table.insert(lines, '-- Do NOT commit this file to the project\'s own repo — add ".nvim.lua" to .gitignore.')
        end
        table.insert(lines, '')
        table.insert(lines, marker)
        for _, line in ipairs(block_lines) do
            table.insert(lines, line)
        end
        vim.fn.writefile(lines, path)
        vim.notify('Updated ' .. path .. ' — remember ".nvim.lua" is in .gitignore', vim.log.levels.WARN)
    end

    -- vim.secure.trust with action='allow' hashes a buffer's live content, not
    -- the file on disk, so load it into a scratch buffer just to compute/store
    -- the hash (this also means future launches skip the exrc trust prompt).
    --
    -- bufload() sets filetype on that scratch buffer, which fires FileType —
    -- and since the block we just wrote registers a `pattern = '*'` FileType
    -- autocmd for the engine being enabled, loading .nvim.lua would otherwise
    -- immediately re-trigger that engine's own attach/completion logic against
    -- whatever buffer happens to be current. eventignore suppresses that.
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

return M
