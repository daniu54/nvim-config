-- Cross-filetype highlights, applied via matchadd() (window-local, regex-based)
-- rather than :syntax, so they work even in plain-text buffers with no syntax
-- file of their own. Highlight groups are defined in colors.lua.
--
-- Priority controls what wins where patterns overlap (e.g. a quoted string
-- inside a commented-out line): higher priority always wins, regardless of
-- match/syntax highlighting priority.
local GROUPS = {
    -- "quoted", 'quoted', `quoted`
    { name = 'HlQuotedString', pattern = [["[^"]*"\|'[^']*'\|`[^`]*`]], priority = 12 },
    -- (parenthesised text) — non-greedy so `(a) x (b)` gives two matches, not one
    { name = 'HlParenText',    pattern = [[(.\{-})]],                   priority = 11 },
    -- literal \n / \t escape sequences — highest priority so they still stand
    -- out even inside an already-highlighted quoted string
    { name = 'HlEscapeSequence', pattern = [=[\\[nt]]=],                priority = 13 },
    -- /command words — must start a word (after whitespace or line start) to
    -- avoid matching mid-token things like inline division `a/b`
    { name = 'HlSlashCommand', pattern = [[\(^\|\s\)\zs/\S\+]],         priority = 12 },
    -- -command / --command words — must start a word (after whitespace or line
    -- start), same reasoning as slash-commands (avoid mid-token hyphens)
    { name = 'HlFlagCommand',  pattern = [[\(^\|\s\)\zs--\?[A-Za-z_][-A-Za-z0-9_]*]], priority = 12 },
    -- whole-line comments: gray, but lower priority than the groups above so
    -- quoted/parenthesised/slash content inside a comment still highlights
    { name = 'HlGrayComment',  pattern = [[^\s*\(#\|//\).*$]],          priority = 5 },
}

local function apply_matches()
    if vim.w.custom_hl_applied then
        return
    end
    for _, g in ipairs(GROUPS) do
        vim.fn.matchadd(g.name, g.pattern, g.priority)
    end
    vim.w.custom_hl_applied = true
end

vim.api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter', 'VimEnter' }, {
    callback = apply_matches,
})
