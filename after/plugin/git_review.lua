-- git_review.lua — :GitReview, a branch's worth of commits as one markdown buffer.
--
-- WHY: reviewing a branch by opening the changed files one at a time loses the
-- thing that makes a review a review — the order the work happened in, and the
-- message explaining why. Every nvim review plugin out there (diffview.nvim,
-- octo.nvim, gh-review.nvim, reviewthem.nvim) answers this with a *file tree
-- plus a side-by-side pane*: a UI to drive. This answers it with a document:
-- one markdown file holding every commit on the branch, its message, and its
-- per-file diffs as ```diff blocks — top to bottom, oldest commit first, the
-- way you would read a patch series in a mail client.
--
-- The point of it being an ordinary buffer (the same argument as :Yanks in
-- after/plugin/yanks.lua): `/`, `n`, visual mode, `yy`, folds and marks all
-- work on it, because it is text. Nothing to learn.
--
-- It is also *writable*, and two things in it are the user's: the
-- `- [ ] <path> has been reviewed` box under each file, and the `//` comments
-- they write under a diff. Both are parsed back out of the previous file and
-- merged into the next render — see "carrying a review forward" below — so the
-- document accumulates a review across the many renders a moving branch needs.
--
-- ```diff fences are load-bearing: markdown's treesitter injection highlights
-- the block as a diff, so +/- lines colour themselves with no work here.

local M = {}

-- ── running git ──────────────────────────────────────────────────────────────

local function git(root, args)
  local cmd = { 'git', '-C', root, '--no-pager' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or '')
  end
  return res.stdout or ''
end

local function lines_of(s)
  return vim.split(s or '', '\n', { plain = true, trimempty = true })
end

-- repo_root resolves the repository containing the current buffer, falling back
-- to the cwd for an unnamed buffer.
local function repo_root()
  local buf = vim.api.nvim_buf_get_name(0)
  local dir = (buf ~= '' and vim.fn.filereadable(buf) == 1) and vim.fs.dirname(buf) or vim.uv.cwd()
  local res = vim.system({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if res.code ~= 0 then return nil end
  return vim.trim(res.stdout)
end

-- base_branch is the branch this one forked from: origin/HEAD's target if the
-- remote publishes one, else the first of main/master that exists.
local function base_branch(root)
  local out = git(root, { 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' })
  if out and vim.trim(out) ~= '' then
    return vim.trim(out):gsub('^origin/', '')
  end
  for _, name in ipairs({ 'main', 'master', 'trunk', 'develop' }) do
    if git(root, { 'rev-parse', '--verify', '--quiet', name }) then return name end
  end
  return nil
end

-- ── resolving what to review ────────────────────────────────────────────────

-- resolve_range turns the command's argument into a `git log` range.
--
-- No argument on a feature branch is the whole point of the command: everything
-- since the fork from main. On the base branch itself there is no such fork, so
-- a depth is required rather than guessed — walking "the last few" commits of
-- main is a decision only the user can make.
--
-- Those two failures are *soft*: the uncommitted section at the top still has
-- something to show, and "what have I changed" is the most common reason to
-- reach for this command on main. So they return a note to print rather than an
-- error to abort on, provided the working tree is dirty.
local function resolve_range(root, arg)
  local branch = vim.trim(git(root, { 'rev-parse', '--abbrev-ref', 'HEAD' }) or 'HEAD')

  if arg and arg ~= '' then
    if arg:match('^%d+$') then
      return ('HEAD~%s..HEAD'):format(arg), branch,
        ('last %s commit%s'):format(arg, arg == '1' and '' or 's')
    end
    if arg:find('%.%.') then
      return arg, branch, arg
    end
    local mb = git(root, { 'merge-base', arg, 'HEAD' })
    if not mb then return nil, branch, nil, ('unknown revision: %s'):format(arg) end
    return ('%s..HEAD'):format(vim.trim(mb)), branch, ('since %s'):format(arg)
  end

  local base = base_branch(root)
  if not base then
    return nil, branch, nil,
      'no main/master branch found — pass a depth (:GitReview 10) or a range', true
  end
  if branch == base then
    return nil, branch, nil,
      ('on the base branch (%s) — pass a depth (:GitReview 10), a base (:GitReview v1.2) or a range (:GitReview a..b)'):format(base),
      true
  end
  local mb = git(root, { 'merge-base', base, 'HEAD' })
  if not mb or vim.trim(mb) == '' then
    return nil, branch, nil, ('no merge base between %s and HEAD'):format(base)
  end
  return ('%s..HEAD'):format(vim.trim(mb)), branch, ('since %s'):format(base)
end

-- ── reading commits ─────────────────────────────────────────────────────────

local FS = '\30' -- field separator; anything that cannot occur in a git field
local RS = '\31'

-- commits_in reads the range as records. Merges are excluded: `git show` prints
-- no diff for one by default, and on a feature branch they are merges *from*
-- the base bringing in other people's work, which is not what is under review.
local function commits_in(root, range)
  local fmt = table.concat({ '%H', '%h', '%an', '%ad', '%s', '%b' }, FS) .. RS
  local out, err = git(root, {
    'log', '--reverse', '--no-merges', '--date=short', '--format=' .. fmt, range,
  })
  if not out then return nil, err end

  local commits = {}
  for _, record in ipairs(vim.split(out, RS, { plain = true })) do
    record = record:gsub('^\n', '')
    if vim.trim(record) ~= '' then
      local f = vim.split(record, FS, { plain = true })
      table.insert(commits, {
        sha = f[1], short = f[2], author = f[3], date = f[4],
        subject = f[5], body = vim.trim(f[6] or ''),
      })
    end
  end
  return commits
end

-- split_diff cuts one commit's full diff into per-file chunks. One `git show`
-- per commit and a split here, rather than a `git show -- <file>` per file:
-- a 40-file commit is one process instead of forty.
local function split_diff(text)
  local files, cur = {}, nil
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local a, b = line:match('^diff %-%-git a/(.-) b/(.+)$')
    if a then
      cur = { path = (a == b) and b or (a .. ' → ' .. b), lines = {}, added = 0, removed = 0 }
      table.insert(files, cur)
    elseif cur then
      -- The heading already names the file, so git's own header lines are
      -- noise — all but the ones that say something a hunk cannot: a new or
      -- deleted file, a rename, a mode change, a binary blob.
      local noise = line:match('^index ') or line:match('^%-%-%- ') or line:match('^%+%+%+ ')
      if noise then goto continue end
      table.insert(cur.lines, line)
      if line:match('^%+') and not line:match('^%+%+%+') then
        cur.added = cur.added + 1
      elseif line:match('^%-') and not line:match('^%-%-%-') then
        cur.removed = cur.removed + 1
      end
      ::continue::
    end
  end
  return files
end

-- fence_for picks a fence long enough to contain the chunk: a diff of a
-- markdown file holds ``` runs of its own, and a three-backtick fence would end
-- the block in the middle of the patch.
local function fence_for(chunk)
  local longest = 2
  for _, line in ipairs(chunk) do
    for run in line:gmatch('`+') do
      longest = math.max(longest, #run)
    end
  end
  return string.rep('`', longest + 1)
end

-- working_changes collects everything not yet in a commit: staged, unstaged and
-- untracked, in that order, each chunk labelled with which it is. Staged and
-- unstaged are kept apart rather than merged into one `git diff HEAD` — when
-- you are about to commit, *which half a hunk is in* is the thing you are
-- checking.
-- An untracked file has no diff of its own, so it is diffed against /dev/null
-- to render as one — every line a +. A big one is named and left at that: an
-- accidental `node_modules` should not become the review.
local function untracked_files(root)
  local out = {}
  for _, path in ipairs(lines_of(git(root, { 'ls-files', '--others', '--exclude-standard' }) or '')) do
    local full = root .. '/' .. path
    local stat = vim.uv.fs_stat(full)
    local f = { path = path, label = 'untracked', lines = {}, added = 0, removed = 0 }
    if stat and stat.size <= 128 * 1024 then
      local res = vim.system({ 'git', '-C', root, '--no-pager', 'diff', '--no-color',
        '--no-index', '--', '/dev/null', path }, { text = true }):wait()
      local chunks = split_diff(res.stdout or '')
      if chunks[1] then
        f.lines, f.added, f.removed = chunks[1].lines, chunks[1].added, chunks[1].removed
      end
    else
      f.lines = { ('(untracked, %s — too large to show)'):format(
        stat and ('%d KiB'):format(math.floor(stat.size / 1024)) or 'unreadable') }
    end
    table.insert(out, f)
  end

  return out
end

-- working_changes collects everything not yet in a commit: staged, unstaged and
-- untracked, in that order, each chunk labelled with which it is. Staged and
-- unstaged are kept apart rather than merged into one `git diff HEAD` — when
-- you are about to commit, *which half a hunk is in* is the thing you are
-- checking.
local function working_changes(root)
  local out = {}

  for _, src in ipairs({
    { label = 'staged', args = { 'diff', '--cached', '--no-color', '--find-renames' } },
    { label = 'unstaged', args = { 'diff', '--no-color', '--find-renames' } },
  }) do
    for _, f in ipairs(split_diff(git(root, src.args) or '')) do
      f.label = src.label
      table.insert(out, f)
    end
  end

  vim.list_extend(out, untracked_files(root))

  return out
end

-- aggregate is the net diff of the whole review — the range's start against the
-- working tree, untracked files included — with no commit boundaries in it.
-- The sections above answer "how did this happen"; this one answers "what does
-- it come to", which is the shape a reviewer signs off on and the one a commit
-- series with a fix-up in it hides.
local function aggregate(root, range)
  local base = range and range:match('^(.-)%.%.') or nil
  if not base or base == '' then return {} end
  local out = split_diff(git(root, { 'diff', '--no-color', '--find-renames', base }) or '')
  vim.list_extend(out, untracked_files(root))
  return out
end

-- ── carrying a review forward ───────────────────────────────────────────────
--
-- The document is regenerated from git on every run, but two things in it are
-- *yours* and have to survive that: the `- [ ] … has been reviewed` boxes, and
-- the `//` comment lines you write under a diff. So the previous file is parsed
-- back before the new one is rendered, and the pieces are merged in.
--
-- The shape it reads is exactly the shape render() writes:
--
--   ### path (+n −m)
--
--   ```diff
--   …                       <- regenerated every run; anything you write in
--   ```                        here is yours to lose
--
--   // a comment            <- carried forward
--   // another
--
--   - [ ] path has been reviewed
--
--   ### the next file       <- nothing between the box and here is carried
--
-- Comments are anchored on (section, path), where the section is `all`,
-- `uncommitted` or `commit:<short sha>` — so an amended commit's comments
-- orphan rather than reattaching to a diff they were not written about.
--
-- The diff *body* is hashed as it is parsed. That hash is the whole change
-- detector: a file whose rendered diff is byte-identical to last time has not
-- changed, whatever the commits underneath it did.

-- section_key turns a `## …` heading back into the key its files were stored
-- under. A commit heading is `## <short> <subject> (<date>)`.
local function section_key(heading)
  if heading == 'All changes' then return 'all' end
  if heading == 'Uncommitted changes' then return 'uncommitted' end
  if heading == 'Orphaned comments' then return 'orphaned' end
  return 'commit:' .. (heading:match('^(%S+)') or heading)
end

local function parse_previous(path)
  local prev = { comments = {}, review = {}, hash = {} }
  if vim.fn.filereadable(path) == 0 then return prev end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return prev end

  local section, file, fence, body, comments

  local function flush()
    if section and file and comments and #comments > 0 then
      prev.comments[section] = prev.comments[section] or {}
      prev.comments[section][file] = comments
    end
    comments = nil
  end

  for _, l in ipairs(lines) do
    if fence then
      if l == fence then
        if section == 'all' and file then
          prev.hash[file] = vim.fn.sha256(table.concat(body, '\n'))
        end
        fence, body = nil, nil
        -- Past the fence is where your comments live.
        comments = {}
      else
        table.insert(body, l)
      end
    else
      local open = l:match('^(`+)diff$')
      if open then
        fence, body = open, {}
      elseif l:match('^#+ ') then
        flush()
        if l:match('^## ') then
          section, file = section_key(l:sub(4)), nil
        elseif l:match('^### ') then
          -- Strip the `(+n −m)` counts and any `*(label)*` suffix back off.
          file = l:sub(5):match('^(.-) %(%+%d+ ') or l:sub(5)
          -- An orphan section has no diff to sit under, so its comments start
          -- at the heading. Without this a rescued block would be rescued
          -- exactly once and then dropped by the render after it.
          comments = (section == 'orphaned') and {} or nil
        else
          section, file = nil, nil
        end
      elseif comments then
        local c = l:match('^%s*(//.*)$')
        local box, boxed = l:match('^%- %[([ xX])%] (.+) has been reviewed')
        if c then
          table.insert(comments, c)
        elseif box then
          prev.review[boxed] = box ~= ' '
          flush()
        elseif l:match('%S') then
          flush()
        end
      end
    end
  end
  flush()

  return prev
end

-- changed_note names *what* unchecked a box: the newest commit in the range
-- that touches the file, with its own commit date — because "this file moved
-- under you" is only useful if it says which commit moved it. A file whose
-- change is not in any commit yet is uncommitted, and the working tree's mtime
-- is the closest thing it has to a timestamp.
local function changed_note(root, range, path)
  if range then
    local out = git(root, { 'log', '-1', '--no-merges', '--format=%h\30%cd',
      '--date=format:%Y-%m-%d at %H:%M', range, '--', path })
    if out and vim.trim(out) ~= '' then
      local sha, when = vim.trim(out):match('^(.-)\30(.+)$')
      if sha then return (' (%s, %s)'):format(sha, when) end
    end
  end
  local st = vim.uv.fs_stat(root .. '/' .. path)
  return (' (uncommitted, %s)'):format(os.date('%Y-%m-%d at %H:%M', st and st.mtime.sec or os.time()))
end

-- ── rendering ───────────────────────────────────────────────────────────────

-- render builds the document, and alongside it `index`: for each buffer line,
-- the file and line in the working tree it corresponds to, so <CR> can jump.
local function render(root, branch, range, label, commits, working, note, prev, rotated)
  local out, index = {}, {}
  local function put(line) table.insert(out, line) end

  -- Which of the previous run's comment blocks have been re-emitted, so that
  -- the ones whose file or commit is gone can be rescued at the bottom rather
  -- than deleted by a re-render.
  local used = {}

  local function emit_comments(section, path)
    local block = section and prev.comments[section] and prev.comments[section][path]
    if not block then return end
    used[section .. '\0' .. path] = true
    put('')
    for _, c in ipairs(block) do put(c) end
  end

  -- The review box. It stays ticked only while the file's rendered diff is
  -- byte-identical to the one you ticked it against; the moment that changes —
  -- an amend, a new commit, an edit in the working tree — it comes back
  -- unticked, naming what changed it.
  local function review_box(f, body)
    local checked = prev.review[f.path] or false
    local was = prev.hash[f.path]
    local suffix = ''
    if checked and was and was ~= vim.fn.sha256(table.concat(body, '\n')) then
      checked, suffix = false, changed_note(root, range, f.path:match('[^ ]+$'))
    end
    put('')
    put(('- [%s] %s has been reviewed%s'):format(checked and 'x' or ' ', f.path, suffix))
  end

  -- emit_file writes one `### path (+a −b)` section and its fenced diff, and
  -- records, for every line that exists on the + side, which working-tree line
  -- it is — the index <CR> jumps on. Your comments go after the fence, and the
  -- review box (`## All changes` only) after those.
  local function emit_file(f, opts)
    opts = opts or {}
    put(('### %s (+%d −%d)%s'):format(f.path, f.added, f.removed, opts.suffix or ''))
    put('')
    local fence = fence_for(f.lines)
    put(fence .. 'diff')
    local newline = nil -- current line number on the + side
    for _, l in ipairs(f.lines) do
      put(l)
      local start = l:match('^@@ %-%d+[,%d]* %+(%d+)')
      if start then
        newline = tonumber(start)
      elseif newline and not l:match('^%-') and not l:match('^\\') then
        index[#out] = { file = f.path:match('[^ ]+$'), line = newline }
        newline = newline + 1
      end
    end
    put(fence)
    emit_comments(opts.section, f.path)
    if opts.review then review_box(f, f.lines) end
    put('')
  end

  -- Anything the previous run held that this one had no place for. It is
  -- re-emitted under a heading of its own so that a re-render cannot quietly
  -- delete something you wrote — and parsed back out of that heading next time,
  -- so it stays until you move it or delete it yourself.
  local function emit_orphans()
    local orphans = {}
    for section, files in pairs(prev.comments) do
      for path, block in pairs(files) do
        if not used[section .. '\0' .. path] then
          table.insert(orphans, { section = section, path = path, block = block })
        end
      end
    end
    if #orphans == 0 then return end
    table.sort(orphans, function(a, b)
      return (a.section .. '\0' .. a.path) < (b.section .. '\0' .. b.path)
    end)

    put('## Orphaned comments')
    put('')
    put('Comments from an earlier revision whose file or commit is no longer in this review — an amended commit, a reverted file. Nothing regenerates them; move them or delete them.')
    put('')
    for _, o in ipairs(orphans) do
      -- An already-orphaned block keeps its heading verbatim, or the prefix
      -- would grow by one section name on every render.
      put('### ' .. (o.section == 'orphaned' and o.path or ('%s — %s'):format(o.section, o.path)))
      put('')
      for _, c in ipairs(o.block) do put(c) end
      put('')
    end
  end

  put(('# Branch %s'):format(branch))
  put('')
  -- The repo root, in the document itself. It reads as information, and it is
  -- also how a review reopened in a fresh nvim recovers the directory its
  -- relative paths are written against — see the BufReadPost autocmd below.
  put(('Repo: `%s`'):format(root))
  if rotated then
    put(('Previous revision: `%s`'):format(rotated))
  end

  if #commits > 0 then
    put(('Contains %d commit%s (%s), merges excluded.')
      :format(#commits, #commits == 1 and '' or 's', label or range))
    put(('First commit: `%s` %s — %s'):format(commits[1].short, commits[1].date, commits[1].subject))
    local last = commits[#commits]
    put(('Last commit:  `%s` %s — %s'):format(last.short, last.date, last.subject))
  elseif note then
    put(note)
  else
    put(('No commits in `%s`.'):format(range))
  end
  if #working > 0 then
    local n = { staged = 0, unstaged = 0, untracked = 0 }
    for _, f in ipairs(working) do n[f.label] = n[f.label] + 1 end
    put(('Uncommitted: %d staged, %d unstaged, %d untracked.')
      :format(n.staged, n.unstaged, n.untracked))
  end
  put('')

  -- Uncommitted first, because it is the part still in your hands: the diffs
  -- below it are history and cannot be edited, this one is what you are about
  -- to commit.
  if #working > 0 then
    put('## Uncommitted changes')
    put('')
    for _, f in ipairs(working) do
      emit_file(f, { suffix = ('  *(%s)*'):format(f.label), section = 'uncommitted' })
    end
  end

  -- Then the same work with the commits taken out. It sits above the commit
  -- sections because it is what a reviewer reads first — what the branch comes
  -- to — with the series below it as the explanation of how it got there.
  local net = aggregate(root, range)
  if #net > 0 then
    local base = range:match('^(.-)%.%.')
    put('## All changes')
    put('')
    put(('The whole review as one diff — `%s` against the working tree, %d file%s, no commit boundaries.')
      :format(base, #net, #net == 1 and '' or 's'))
    put('')
    -- This is the section you sign off on, so this is the section with the
    -- boxes in it: one per file, ticked by you once you have read that file.
    for _, f in ipairs(net) do
      emit_file(f, { section = 'all', review = true })
    end
  end

  -- With no range there was nothing to aggregate that the uncommitted section
  -- did not already show, so this is also the end of the document.
  if #commits == 0 then
    emit_orphans()
    return out, index
  end

  for _, c in ipairs(commits) do
    local text = git(root, { 'show', '--format=', '--no-color', '--find-renames', c.sha }) or ''
    local files = split_diff(text)

    put(('## %s %s (%s)'):format(c.short, c.subject, c.date))
    put('')
    if c.body ~= '' then
      for _, l in ipairs(vim.split(c.body, '\n', { plain = true })) do
        put(l == '' and '>' or ('> ' .. l))
      end
      put('')
    end
    put(('*%s · %d file%s changed*'):format(c.author, #files, #files == 1 and '' or 's'))
    put('')

    for _, f in ipairs(files) do
      emit_file(f, { section = 'commit:' .. c.short })
    end
  end

  emit_orphans()

  return out, index
end

-- ── the buffer ──────────────────────────────────────────────────────────────

-- The review is written to a real file under /tmp/git-reviews/ rather than held
-- in a scratch buffer: it *is* a markdown document, and being one on disk means
-- it can be reopened, diffed, handed to a pager or exported by :ConvertToPdf
-- like any other. One file per repo+branch, overwritten on every render — a
-- second :GitReview refreshes it rather than stacking windows onto stale copies
-- of a branch that moves under them.
local REVIEW_DIR = '/tmp/git-reviews'

-- The review buffer lives outside the repository it describes, so repo_root()
-- would resolve /tmp, not the branch under review. Everything a keymap needs —
-- the repo root, the jump index, the window to jump into — is therefore stored
-- per buffer here rather than rediscovered from the buffer's own name.
local reviews = {}

local function jump()
  local st = reviews[vim.api.nvim_get_current_buf()]
  if not st then return end
  local hit = st.index[vim.api.nvim_win_get_cursor(0)[1]]
  if not hit then
    -- Not a diff line: a `### path` heading, the `Repo:` line, a path named in
    -- a commit message. Hand it to the same `<CR>` every other buffer has —
    -- b:open_under_cursor_cwd points it at the repo, so a relative path in the
    -- document resolves there and not at the review file's own /tmp directory.
    return require('shared.open_under_cursor').open_under_cursor({ silent = true })
  end
  local root = st.root
  local path = root .. '/' .. hit.file
  if vim.fn.filereadable(path) == 0 then
    return vim.notify(('not in the working tree: %s'):format(hit.file), vim.log.levels.WARN)
  end
  -- Open in the window :GitReview was called from, keeping the review visible.
  if st.origin and vim.api.nvim_win_is_valid(st.origin) then
    vim.api.nvim_set_current_win(st.origin)
  else
    vim.cmd('wincmd p')
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { hit.line, 0 })
  vim.cmd('normal! zz')
end

-- review_path is the handle: /tmp/git-reviews/<repo>-<branch>.md, so the same
-- branch always lands on the same file and two repos never share one.
local function review_path(root, branch)
  vim.fn.mkdir(REVIEW_DIR, 'p')
  local repo = vim.fn.fnamemodify(root, ':t')
  local name = repo .. '-' .. (branch or 'review')
  name = (name:gsub('[^%w%.%-_]', '-'):gsub('%-+', '-'):gsub('^%-', ''):gsub('%-$', ''))
  return REVIEW_DIR .. '/' .. name .. '.md'
end

-- Every render moves the file it is about to replace aside, so the ticks and
-- comments of each round survive as a dated snapshot next to the current one.
-- Seconds, not just the date: `R` refreshes a review several times an hour.
-- Nothing prunes these — they are in /tmp and the history is the point.
local function revision_path(path)
  return (path:gsub('%.md$', '')) .. '-revision-' .. os.date('%Y-%m-%d-%H%M%S') .. '.md'
end

-- The review buffer is editable now — the boxes and the comments are typed
-- into it — so its unsaved state is the newest version of the review, and the
-- next render reads the *file*. Flush it first, without autocmds: an explicit
-- write would hand the document to prettier, and reflowing it is the one thing
-- that can break the shape parse_previous reads back.
local function flush_buf(path)
  local buf = vim.fn.bufnr(path)
  if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) or not vim.bo[buf].modified then return end
  pcall(function()
    vim.api.nvim_buf_call(buf, function() vim.cmd('silent noautocmd write') end)
  end)
end

local function ensure_buf(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  if reviews[buf] then return buf end
  reviews[buf] = {}
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  -- The document is writable — the review boxes and the `//` comments are typed
  -- into it, and autosave keeps them. Two things have to be kept off it:
  --   * prettier, which reflows markdown and would break the exact shape
  --     parse_previous reads the boxes and comments back out of
  --   * markdown_table.lua's <Tab>/<CR>, since <CR> here opens the diff line
  --     under the cursor
  vim.b[buf].no_autoformat = true
  vim.b[buf].markdown_table_off = true
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function() reviews[buf] = nil end,
  })

  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map('q', function() vim.cmd('close') end, 'close the review')
  map('R', function()
    local st = reviews[buf] or {}
    M.open(vim.tbl_extend('force', st.args or {}, { root = st.root }))
  end, 'refresh')
  map('<CR>', jump, 'open the file at this diff line')
  -- Commit-to-commit movement, since a review is read commit by commit.
  map(']]', function() vim.fn.search('^## ', 'W') end, 'next commit')
  map('[[', function() vim.fn.search('^## ', 'bW') end, 'previous commit')
  return buf
end

function M.open(opts)
  -- The review buffer sits in /tmp, outside the repository it describes, so
  -- repo_root() from inside one answers nothing. Three fallbacks, in the order
  -- they are trustworthy: the root a refresh passed back, the root this session
  -- rendered the buffer against, and the one a review reopened in a fresh nvim
  -- recovered from its own `Repo:` header. Only then the buffer's own path.
  local cur = vim.api.nvim_get_current_buf()
  local in_review = vim.api.nvim_buf_get_name(cur):find(REVIEW_DIR, 1, true) == 1
  local root = opts.root
    or (reviews[cur] or {}).root
    -- A review reopened in a fresh nvim has no state table, but the BufReadPost
    -- autocmd below has already read the root out of its `Repo:` header.
    or (in_review and vim.b[cur].open_under_cursor_cwd or nil)
    or repo_root()
  if not root then
    return vim.notify('not inside a git repository', vim.log.levels.ERROR)
  end

  local range, branch, label, err, soft = resolve_range(root, opts.arg)
  local working = working_changes(root)
  local note
  if not range then
    -- A dirty tree still has something worth showing, so a soft failure becomes
    -- a note at the top rather than an aborted command.
    if not (soft and #working > 0) then
      return vim.notify(err, vim.log.levels.ERROR)
    end
    note, range = ('No commit range: %s'):format(err), nil
  end

  local commits = {}
  if range then
    local log_err
    commits, log_err = commits_in(root, range)
    if not commits then
      return vim.notify(('git log %s failed: %s'):format(range, log_err), vim.log.levels.ERROR)
    end
  end

  -- The previous revision has to be read before it is replaced, and the buffer
  -- written before it is read.
  local path = review_path(root, branch)
  flush_buf(path)
  local prev = parse_previous(path)

  -- Named before the render so the new document can point back at it, and
  -- renamed after it so a failed render leaves the old review in place.
  local rotated = vim.fn.filereadable(path) == 1 and revision_path(path) or nil

  local out, index = render(root, branch, range, label, commits, working, note, prev, rotated)

  if rotated and not os.rename(path, rotated) then rotated = nil end
  local ok, werr = pcall(vim.fn.writefile, out, path)
  if not ok then
    return vim.notify(('could not write %s: %s'):format(path, werr), vim.log.levels.ERROR)
  end
  local buf = ensure_buf(path)
  local st = reviews[buf]
  st.index, st.args, st.root = index, { arg = opts.arg, vertical = opts.vertical }, root
  -- Every path in this document is relative to the repo, but the document
  -- itself lives in /tmp — so open_under_cursor's `<CR>`/`gf`/`<leader>gf`
  -- would resolve them against /tmp/git-reviews and find nothing. This is the
  -- override that module documents for exactly this case.
  vim.b[buf].open_under_cursor_cwd = root

  -- Reload from the file rather than setting the lines by hand. The buffer is
  -- writable and autosaved now, so it has to end up *stamped as in sync with
  -- disk* — which is what BufReadPost gives it (see after/plugin/autosave.lua).
  -- Setting the lines behind vim's back would leave the buffer looking older
  -- than the file it was just rendered from, and the next keystroke would raise
  -- an autosave conflict over a file only this command had touched.
  vim.api.nvim_buf_call(buf, function() vim.cmd('silent! edit!') end)

  -- Show it. A vertical split for :GitReview! — a diff is wide, and a tall
  -- narrow window next to the code is often the better shape for reading one.
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    st.origin = vim.api.nvim_get_current_win()
    vim.cmd(opts.vertical and 'botright vsplit' or 'tab split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_current_win(win)
  -- Wrapped, because this is prose with diffs in it and a review is read, not
  -- scrolled sideways: linebreak keeps the wrap on word boundaries and
  -- breakindent keeps a continued diff line under its own +/- column.
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].conceallevel = 0
  -- Folds on the markdown headings, all open: `zM` collapses to one line per
  -- commit, which is the table of contents for the branch.
  vim.wo[win].foldmethod = 'expr'
  vim.wo[win].foldexpr = "getline(v:lnum)=~'^# ' ? '>1' : getline(v:lnum)=~'^## ' ? '>2' : getline(v:lnum)=~'^### ' ? '>3' : '='"
  vim.wo[win].foldlevel = 99
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

-- A review file outlives the session that wrote it: reopened in a fresh nvim it
-- is just markdown in /tmp, with no state table behind it. The `Repo:` line in
-- its header is enough to point path resolution back at the repository, so the
-- file's paths stay followable with `gf` and `<CR>` on their own.
vim.api.nvim_create_autocmd('BufReadPost', {
  pattern = REVIEW_DIR .. '/*.md',
  callback = function(ev)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(ev.buf, 0, 10, false)) do
      local root = line:match('^Repo: `(.+)`$')
      if root and vim.fn.isdirectory(root) == 1 then
        vim.b[ev.buf].open_under_cursor_cwd = root
        return
      end
    end
  end,
})

vim.api.nvim_create_user_command('GitReview', function(cmd)
  M.open({ arg = vim.trim(cmd.args), vertical = cmd.bang })
end, {
  nargs = '?',
  bang = true,
  desc = 'review the branch: every commit and its diffs as one markdown buffer',
  complete = function(lead)
    local root = repo_root()
    if not root then return {} end
    local out = git(root, { 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes' }) or ''
    return vim.tbl_filter(function(r) return r:find(lead, 1, true) == 1 end, lines_of(out))
  end,
})

return M
