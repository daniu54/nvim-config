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
    { name = 'HlHighlight', pattern = [=[v\?\d\+\.\d\+\%(\.\d\+\)\?\%(-[[:alnum:]._-]\+\)\?]=], priority = 9 },
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
    { name = 'HlHighlight', pattern = [=[https\?://[^[:space:]'"]\+]=], priority = 11 },
    -- "quoted", 'quoted', `quoted`
    { name = 'HlQuotedString', pattern = [["[^"]*"\|'[^']*'\|`[^`]*`]], priority = 13 },
    -- (parenthesised text) — non-greedy so `(a) x (b)` gives two matches, not one.
    -- Lowest priority of all groups so content inside parens/brackets (numbers,
    -- error words, paths, ...) still highlights as itself rather than as paren/bracket text.
    { name = 'HlParenText',    pattern = [[(.\{-})]],                   priority = 1 },
    -- [bracketed text] — same treatment as parenthesised text above
    { name = 'HlBracketText', pattern = [=[\[.\{-}\]]=], priority = 1 },
    -- literal \n / \t escape sequences — highest priority so they still stand
    -- out even inside an already-highlighted quoted string
    { name = 'HlEscapeSequence', pattern = [=[\\[nt]]=],                priority = 14 },
    -- /command words — must start a word (after whitespace or line start) to
    -- avoid matching mid-token things like inline division `a/b`
    { name = 'HlSlashCommand', pattern = [[\(^\|\s\)\zs/\S\+]],         priority = 13 },
    -- -command / --command words — must start a word (after whitespace or line
    -- start), same reasoning as slash-commands (avoid mid-token hyphens)
    { name = 'HlFlagCommand',  pattern = [[\(^\|\s\)\zs--\?[A-Za-z_][-A-Za-z0-9_]*]], priority = 13 },
    -- ClickUp task IDs: alphanumeric tokens mixing at least one digit and one
    -- letter (e.g. `86c8fxwd0`), mirroring looksLikeTaskID() in
    -- clickup-terminal's cmd/resolve.go
    { name = 'HlClickupId', pattern = [=[\<\%([0-9A-Za-z]*\d\)\@=\%([0-9A-Za-z]*[A-Za-z]\)\@=[0-9A-Za-z]\+\>]=], priority = 13 },
    -- error / warning / success keywords — above quotes/escapes so they still
    -- stand out inside quoted log lines, but below the TODO-style markers.
    -- The negative tier sits one priority above the other two so that a
    -- multi-word negative wins over a positive word inside it: `not found`
    -- also matches `found`, and at equal priority the last-added match would
    -- take the overlap and paint half the phrase green.
    { name = 'HlNegative',        pattern = [=[\c\<\%(err\w*\|fail\%(s\|ed\|ing\|ure\%(s\)\?\)\?\|exception\%(s\)\?\|fatal\|panic\%(ked\)\?\|denied\|deny\|bugs\?\|block\%(s\|ed\|ing\)\?\|issues\?\|stopped\|stops\?\|reject\%(s\|ed\|ing\|ion\)\?\|refus\%(e\|es\|ed\|ing\|al\)\|abort\%(s\|ed\|ing\)\?\|cannot\|can't\|couldn't\|unable\|invalid\|missing\|not found\|no such\|unauthori[sz]ed\|forbidden\|timeout\|timed out\|crash\%(es\|ed\|ing\)\?\|corrupt\%(ed\|ion\)\?\|conflicts\?\|conflicting\|broken\|broke\|killed\|terminated\|unavailable\|unsupported\|unresolved\|undefined\|unexpected\|violat\%(es\|ed\|ion\%(s\)\?\)\|rollback\|rolled back\|revert\%(s\|ed\)\?\|discarded\|cancel\%(s\|ed\|led\|ling\)\?\|no\)\>]=], priority = 16 },
    { name = 'HlLesserHighlight', pattern = [=[\c\<\%(warn\w*\|disabl\w*\|deprecated\|pending\|retry\%(ing\)\?\|retries\|skip\%(s\|ped\|ping\)\?\|ignor\%(e\|es\|ed\|ing\)\|remov\%(e\|es\|ed\|ing\)\|delet\%(e\|es\|ed\|ing\)\|unchanged\|cached\|stale\|outdated\|partial\%(ly\)\?\|experimental\|dirty\|untracked\|waiting\|queued\)\>]=], priority = 15 },
    { name = 'HlSuccess',         pattern = [=[\c\<\%(success\w*\|succeed\%(s\|ed\)\?\|pass\%(ed\|es\)\?\|good\|ok\|okay\|done\|complet\%(e\|es\|ed\)\|closed\|start\%(s\|ed\)\?\|appl\%(y\|ies\|ied\)\|creat\%(e\|es\|ed\)\|add\%(s\|ed\)\?\|install\%(s\|ed\|ing\)\?\|updat\%(e\|es\|ed\)\|upgrad\%(e\|es\|ed\)\|sav\%(e\|es\|ed\)\|wrote\|written\|load\%(s\|ed\)\?\|connected\|enabled\|ready\|valid\|found\|merged\|pushed\|pulled\|committed\|cloned\|checked out\|resolved\|fixed\|synced\|available\|initiali[sz]ed\|verified\|accepted\|granted\|allowed\|approved\|finished\|built\|generated\|up to date\|active\|healthy\|running\|listening\|yes\)\>]=], priority = 15 },
    -- whole-line comments: gray, but lower priority than the groups above so
    -- quoted/parenthesised/slash content inside a comment still highlights
    { name = 'HlGrayComment',  pattern = [[^\s*\(#\|//\).*$]],          priority = 5 },
    -- list items whose text starts with "#" (e.g. clickuptodos' commented-out
    -- list-item instructions, "- # /new ..." — see clickup-terminal's
    -- commentOutInstructionLine): same whole-line gray treatment as a plain
    -- "#"/"//" comment above, just with a leading list/checklist marker
    -- (-, *, +, or an ordered "1."/"1)", optionally with a "[ ]"/"[x]" box)
    { name = 'HlGrayComment',  pattern = [=[^\s*\%([-*+]\|\d\+[.)]\)\s\+\%(\[[ xX]\]\s\+\)\?#.*$]=], priority = 5 },
    -- trailing "# " comment, anywhere in a line (not just at the start):
    -- everything from the "#" to end of line grays out. Above priority 13
    -- (commands/quotes/paths/etc.) so those don't "shine through" a trailing
    -- comment the way they intentionally do for the whole-line comment rules
    -- above — but still below the success/error/info tier (15/16) and TODO/
    -- FIXME/NOTE/BUG (20), so those still stand out even inside a comment.
    { name = 'HlGrayComment',  pattern = [=[#\s.*$]=],                    priority = 14 },
    -- TODO / FIXME / NOTE / BUG markers — matched anywhere, even mid-word
    -- (e.g. `testTODObuh`), and even inside comments/strings, hence top priority
    { name = 'HlHighlight',       pattern = [[TODO]],                  priority = 20 },
    { name = 'HlNegative',        pattern = [[FIXME]],                 priority = 20 },
    { name = 'HlLesserHighlight', pattern = [[NOTE]],                  priority = 20 },
    { name = 'HlNegative',        pattern = [[BUG]],                   priority = 20 },
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
