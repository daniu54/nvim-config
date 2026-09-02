-- git_review.lua — :GitReview, a branch's worth of commits as one markdown buffer.
--
-- WHY: reviewing a branch by opening the changed files one at a time loses the
-- thing that makes a review a review — the order the work happened in, and the
-- message explaining why. Every nvim review plugin out there (diffview.nvim,
-- octo.nvim, gh-review.nvim, reviewthem.nvim) answers this with a *file tree
-- plus a side-by-side pane*: a UI to drive. This answers it with a document:
-- one scratch markdown buffer holding every commit on the branch, its message,
-- and its per-file diffs as ```diff blocks — top to bottom, oldest commit
-- first, the way you would read a patch series in a mail client.
--
-- The point of it being an ordinary buffer (the same argument as :Yanks in
-- after/plugin/yanks.lua): `/`, `n`, visual mode, `yy`, folds and marks all
-- work on it, because it is text. Nothing to learn.
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

-- ── rendering ───────────────────────────────────────────────────────────────

-- render builds the document, and alongside it `index`: for each buffer line,
-- the file and line in the working tree it corresponds to, so <CR> can jump.
local function render(root, branch, range, label, commits, working, note)
  local out, index = {}, {}
  local function put(line) table.insert(out, line) end

  -- emit_file writes one `### path (+a −b)` section and its fenced diff, and
  -- records, for every line that exists on the + side, which working-tree line
  -- it is — the index <CR> jumps on.
  local function emit_file(f, suffix)
    put(('### %s (+%d −%d)%s'):format(f.path, f.added, f.removed, suffix or ''))
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
    put('')
  end

  put(('# Branch %s'):format(branch))
  put('')

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
      emit_file(f, ('  *(%s)*'):format(f.label))
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
    for _, f in ipairs(net) do
      emit_file(f)
    end
  end

  -- With no range there was nothing to aggregate that the uncommitted section
  -- did not already show, so this is also the end of the document.
  if #commits == 0 then return out, index end

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
      emit_file(f)
    end
  end

  return out, index
end

-- ── the buffer ──────────────────────────────────────────────────────────────

-- One buffer, reused (as :Yanks does): a second :GitReview refreshes it rather
-- than stacking windows onto stale copies of a branch that moves under them.
local state = { buf = nil, index = {}, args = nil, origin = nil }

local function jump()
  local hit = state.index[vim.api.nvim_win_get_cursor(0)[1]]
  if not hit then
    return vim.notify('no file line under the cursor', vim.log.levels.WARN)
  end
  local root = repo_root() or vim.uv.cwd()
  local path = root .. '/' .. hit.file
  if vim.fn.filereadable(path) == 0 then
    return vim.notify(('not in the working tree: %s'):format(hit.file), vim.log.levels.WARN)
  end
  -- Open in the window :GitReview was called from, keeping the review visible.
  if state.origin and vim.api.nvim_win_is_valid(state.origin) then
    vim.api.nvim_set_current_win(state.origin)
  else
    vim.cmd('wincmd p')
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { hit.line, 0 })
  vim.cmd('normal! zz')
end

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  pcall(vim.api.nvim_buf_set_name, buf, 'git-review')

  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map('q', function() vim.cmd('close') end, 'close the review')
  map('R', function() M.open(state.args or {}) end, 'refresh')
  map('<CR>', jump, 'open the file at this diff line')
  -- Commit-to-commit movement, since a review is read commit by commit.
  map(']]', function() vim.fn.search('^## ', 'W') end, 'next commit')
  map('[[', function() vim.fn.search('^## ', 'bW') end, 'previous commit')
  return buf
end

function M.open(opts)
  state.args = opts
  local root = repo_root()
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

  local out, index = render(root, branch, range, label, commits, working, note)
  local buf = ensure_buf()
  state.index = index

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  -- Show it. A vertical split for :GitReview! — a diff is wide, and a tall
  -- narrow window next to the code is often the better shape for reading one.
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    state.origin = vim.api.nvim_get_current_win()
    vim.cmd(opts.vertical and 'botright vsplit' or 'tab split')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_current_win(win)
  vim.wo[win].wrap = false
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
