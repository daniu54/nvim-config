-- Cross-filetype highlights, applied via matchadd() (window-local, regex-based)
-- rather than :syntax, so they work even in plain-text buffers with no syntax
-- file of their own. Highlight groups are defined in colors.lua.
--
-- Priority controls what wins where patterns overlap (e.g. a quoted string
-- inside a commented-out line): higher priority always wins, regardless of
-- match/syntax highlighting priority.
local GROUPS = {
    -- Below: merged from the zsh/grc-based command-output colorizer profiles
    -- (~/dotfiles/grc/conf.generic, conf.zig — now removed), since this
    -- matchadd() approach covers the same ground in-editor and works better
    -- (applies to any buffer, not just piped command output).

    -- plain standalone numbers, including decimals/negatives/percents —
    -- lookaround excludes digits embedded in a larger word/dotted token
    -- (e.g. `abc123`, `file2.txt`) so only free-standing numbers match
    { name = 'HlNumber', pattern = [=[\%(\w\|\.\)\@1<!-\?\d\+\%(\.\d\+\)\?%\?\%(\w\|\.\)\@!]=], priority = 6 },
    -- standalone HH:MM times — above plain numbers so `14:30` highlights as
    -- one unit (with its colon) instead of two separate number matches
    { name = 'HlTime', pattern = [=[\%(\d\)\@1<!\d\d:\d\d\%(\d\)\@!]=], priority = 7 },
    -- ISO-ish dates / timestamps: YYYY-MM-DD with optional time-of-day
    { name = 'HlDate', pattern = [=[\d\{4}-\d\{2}-\d\{2}\%([ T]\d\{2}:\d\{2}\%(:\d\{2}\)\?\%(\.\d\+\)\?Z\?\)\?]=], priority = 8 },
    -- semantic-ish version numbers (1.2.3, v1.2, 1.2.3-beta.1)
    { name = 'HlVersion', pattern = [=[v\?\d\+\.\d\+\%(\.\d\+\)\?\%(-[[:alnum:]._-]\+\)\?]=], priority = 9 },
    -- file paths (with a directory component, unix or windows-style) and
    -- bare filenames, both with an optional :line or :line:col suffix.
    -- Extension must start with a letter so plain decimals (`3.14`) don't
    -- get misread as a bare filename.
    --
    -- The `~[\\/]...` branch is separate from the generic dir/file branch
    -- below it: that one requires two path segments (or a name.ext with a
    -- word boundary before the name), so a single dotfile right after the
    -- prefix — `~/.zsh_history` (no 2nd `/`, and no 2nd `.` to read as an
    -- extension) — never matched at all, and `~/.zshrc.secrets` only
    -- matched the bare `zshrc.secrets` tail (no word boundary starts on
    -- `.`, so the `~/.` prefix was left out of the match/highlight).
    { name = 'HlFilePath', pattern = [=[\%(\~[\\/][[:alnum:]_./\\-]\+\|\%(\%(\a:[\\/]\|\.\.\?[\\/]\|[\\/]\)\?[[:alnum:]_.-]\+[\\/][[:alnum:]_./\\-]\+\.\a[[:alnum:]]\{0,7}\|\<[[:alnum:]_-]\+\.\a[[:alnum:]]\{0,7}\)\)\%(:\d\+\%(:\d\+\)\?\)\?\>]=], priority = 10 },
    -- URLs — higher priority than plain paths, so a URL's own path segment
    -- (e.g. the `/foo/bar.tar.gz` in `https://example.com/foo/bar.tar.gz`)
    -- doesn't get re-colored as a bare file path
    { name = 'HlUrl', pattern = [=[https\?://[^[:space:]'"]\+]=], priority = 11 },
    -- "quoted", 'quoted', `quoted`
    { name = 'HlQuotedString', pattern = [["[^"]*"\|'[^']*'\|`[^`]*`]], priority = 13 },
    -- (parenthesised text) — non-greedy so `(a) x (b)` gives two matches, not one
    { name = 'HlParenText',    pattern = [[(.\{-})]],                   priority = 12 },
    -- [bracketed text] — same treatment as parenthesised text above
    { name = 'HlBracketText', pattern = [=[\[.\{-}\]]=], priority = 12 },
    -- literal \n / \t escape sequences — highest priority so they still stand
    -- out even inside an already-highlighted quoted string
    { name = 'HlEscapeSequence', pattern = [=[\\[nt]]=],                priority = 14 },
    -- /command words — must start a word (after whitespace or line start) to
    -- avoid matching mid-token things like inline division `a/b`
    { name = 'HlSlashCommand', pattern = [[\(^\|\s\)\zs/\S\+]],         priority = 13 },
    -- -command / --command words — must start a word (after whitespace or line
    -- start), same reasoning as slash-commands (avoid mid-token hyphens)
    { name = 'HlFlagCommand',  pattern = [[\(^\|\s\)\zs--\?[A-Za-z_][-A-Za-z0-9_]*]], priority = 13 },
    -- error / warning / success keywords — above quotes/escapes so they still
    -- stand out inside quoted log lines, but below the TODO-style markers
    { name = 'HlErrorWord',   pattern = [=[\c\<\%(errors\?\|err\|fails\?\|failed\|failure\|exception\|fatal\|panic\|denied\)\>]=], priority = 15 },
    { name = 'HlWarnWord',    pattern = [=[\c\<warn\%(ing\)\?s\?\>]=], priority = 15 },
    { name = 'HlSuccessWord', pattern = [=[\c\<\%(success\%(ful\%(ly\)\?\)\?\|succeeded\|passed\|ok\|done\|completed\)\>]=], priority = 15 },
    -- whole-line comments: gray, but lower priority than the groups above so
    -- quoted/parenthesised/slash content inside a comment still highlights
    { name = 'HlGrayComment',  pattern = [[^\s*\(#\|//\).*$]],          priority = 5 },
    -- TODO / FIXME / NOTE / BUG markers — matched anywhere, even mid-word
    -- (e.g. `testTODObuh`), and even inside comments/strings, hence top priority
    { name = 'HlTodoMarker',  pattern = [[TODO]],                      priority = 20 },
    { name = 'HlFixmeMarker', pattern = [[FIXME]],                     priority = 20 },
    { name = 'HlNoteMarker',  pattern = [[NOTE]],                      priority = 20 },
    { name = 'HlBugMarker',   pattern = [[BUG]],                       priority = 20 },
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
