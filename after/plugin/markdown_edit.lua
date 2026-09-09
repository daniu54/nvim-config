-- markdown_edit.lua — surround + list-toggle keymaps ported from the Obsidian
-- vimrc (`/mnt/d/obsidian_notes/default_vault/default/.obsidian.vimrc`), so the
-- same muscle memory works in nvim.
--
-- Each mapping works two ways, exactly like `exmap … surround` does in
-- obsidian-vimrc-support:
--   * visual mode — wraps the selection
--   * normal mode — wraps the WORD under the cursor (the Obsidian vimrc spells
--     this `nmap ~ viw~`; here it is done directly, no visual round-trip, and
--     with iW rather than iw — see word_bounds)
--
-- The wrap is a *toggle*: pressing the same key on already-wrapped text strips
-- the delimiters again rather than nesting a second pair.
--
-- These keys deliberately override vim builtins (chosen over a <leader>
-- namespace so the Obsidian bindings transfer unchanged):
--   ~   was: toggle case of the character under the cursor (g~ still works)
--   `   was: jump-to-mark prefix (`a, ``)
--   '   was: the other jump-to-mark prefix ('a, '') — with ` gone too, there
--       is no jump-to-mark key left at all
--   "   was: the register prefix ("ayy, "+p, "_d typed by hand) — the
--       explicit <leader>Y / <leader>P / <leader>p / <leader>D maps still
--       reach the system and black-hole registers
--   gb  was: Comment.nvim blockwise-comment operator — <leader>C still block
--       comments a visual selection
--
-- <leader>c (code) and <leader>l (link) are the exceptions: they are
-- buffer-local to prose filetypes, so Comment.nvim's line-comment toggle and
-- the <leader>l… LSP/Copilot prefix both survive in code. <leader>q duplicates
-- " deliberately, as a leader-side alias for the same double-quote wrap.

-- Byte range of the WORD under the cursor, or nil when the cursor sits on
-- whitespace. Returns 1-indexed inclusive columns.
--
-- This is iW, not iw: a WORD is a run of non-blanks, so leading and trailing
-- punctuation lands inside the wrap. With the cursor on --word, the code
-- toggle produces the whole flag wrapped, not just the "word" half of it,
-- which is what you want for a flag, a path or a foo.bar() call — and is the
-- one thing iw cannot express.
local function word_bounds()
  local line = vim.fn.getline(".")
  local col  = vim.fn.col(".")
  local i    = 1
  while true do
    local ms, me = line:find("%S+", i)
    if not ms or col < ms then return nil end
    if col <= me then return ms, me end
    i = me + 1
  end
end

-- Because the WORD swallows punctuation, it also swallows the delimiters of an
-- existing wrap: the already-wrapped --word is a single WORD, delimiters and
-- all. Peel them back off so the toggle still sees the text it wrapped and
-- can strip it again.
local function shrink_wrapped(line, s, e, left, right)
  if e - s + 1 >= #left + #right
    and line:sub(s, s + #left - 1) == left
    and line:sub(e - #right + 1, e) == right
  then
    return s + #left, e - #right
  end
  return s, e
end

-- The region a mapping should act on, as (start_line, start_col, end_line,
-- end_col) with 1-indexed inclusive byte columns.
--   visual:  the selection (linewise selections cover the full lines)
--   normal:  the WORD under the cursor, or an empty span at the cursor;
--            `shrink` (optional) peels an existing wrap back off it
local function target_range(visual, shrink)
  if visual then
    local vmode = vim.fn.mode()
    -- leaving visual mode is what publishes the '< and '> marks
    vim.cmd("normal! \27")
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local sl, sc, el, ec = s[2], s[3], e[2], e[3]
    local last = vim.fn.getline(el)
    if vmode == "V" then
      sc = (vim.fn.getline(sl):find("%S")) or 1
      ec = #last
    else
      ec = math.min(ec, #last)
      -- '> sits on the first byte of the last character; cover the whole one
      if ec > 0 then ec = ec + vim.str_utf_end(last, ec) end
    end
    return sl, sc, el, ec
  end

  local s, e = word_bounds()
  local l = vim.fn.line(".")
  if s and shrink then s, e = shrink(vim.fn.getline(l), s, e) end
  if not s then
    -- not on a word: act on an empty span at the cursor
    local col = vim.fn.col(".")
    return l, col, l, col - 1
  end
  return l, s, l, e
end

-- Wrap [sl,sc]..[el,ec] in left/right, or unwrap when it already is.
-- Returns the column just after the inserted `left` on line sl, which is where
-- the cursor belongs for a fresh empty wrap.
local function toggle_surround(left, right, visual)
  local sl, sc, el, ec = target_range(visual, function(line, s, e)
    return shrink_wrapped(line, s, e, left, right)
  end)
  local first, last = vim.fn.getline(sl), vim.fn.getline(el)

  if first:sub(sc - #left, sc - 1) == left and last:sub(ec + 1, ec + #right) == right then
    -- strip: the trailing delimiter first, so sc stays valid
    vim.api.nvim_buf_set_text(0, el - 1, ec, el - 1, ec + #right, {})
    vim.api.nvim_buf_set_text(0, sl - 1, sc - 1 - #left, sl - 1, sc - 1, {})
    vim.fn.cursor(sl, math.max(sc - #left, 1))
    return nil
  end

  -- wrap: trailing delimiter first, for the same reason
  vim.api.nvim_buf_set_text(0, el - 1, ec, el - 1, ec, { right })
  vim.api.nvim_buf_set_text(0, sl - 1, sc - 1, sl - 1, sc - 1, { left })
  local after_left = sc + #left
  vim.fn.cursor(sl, math.min(after_left, #vim.fn.getline(sl)))
  return after_left
end

local function map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

-- ~~strikethrough~~  (overrides the builtin ~ = toggle case; g~ is unaffected)
for _, m in ipairs({ "n", "x" }) do
  map(m, "~", function() toggle_surround("~~", "~~", m == "x") end,
    "Markdown: toggle ~~strikethrough~~")
end

-- `code`  (overrides the builtin ` = jump-to-mark prefix; use ' instead)
for _, m in ipairs({ "n", "x" }) do
  map(m, "`", function() toggle_surround("`", "`", m == "x") end,
    "Markdown: toggle `code`")
end

-- "quote"  (nothing to override — <leader>q was free)
for _, m in ipairs({ "n", "x" }) do
  map(m, "<leader>q", function() toggle_surround('"', '"', m == "x") end,
    'Markdown: toggle "quote"')
end

-- "quote" and 'quote'  (override the builtin " register prefix and ' jump-to-
-- mark; with ` also taken above, no mark-jump key is left — use explicit maps
-- like <leader>Y / <leader>P for the system register)
for _, m in ipairs({ "n", "x" }) do
  map(m, '"', function() toggle_surround('"', '"', m == "x") end,
    'Markdown: toggle "quote"')
  map(m, "'", function() toggle_surround("'", "'", m == "x") end,
    "Markdown: toggle 'quote'")
end

-- [text](url) — wraps as the link text and drops into insert mode inside the
-- empty parens, ready for the URL. Pressing it on an existing [text](…) link
-- unwraps it back to plain text.
local function toggle_link(visual)
  -- same peel as toggle_surround, for the [text](url) shape
  local sl, sc, el, ec = target_range(visual, function(line, s, e)
    local text = line:sub(s, e):match("^%[(.-)%]%(.-%)$")
    if text then return s + 1, s + #text end
    return s, e
  end)
  local first, last = vim.fn.getline(sl), vim.fn.getline(el)

  local url = last:match("^%]%((.-)%)", ec + 1)
  if first:sub(sc - 1, sc - 1) == "[" and url then
    vim.api.nvim_buf_set_text(0, el - 1, ec, el - 1, ec + #url + 3, {})
    vim.api.nvim_buf_set_text(0, sl - 1, sc - 2, sl - 1, sc - 1, {})
    vim.fn.cursor(sl, math.max(sc - 1, 1))
    return
  end

  vim.api.nvim_buf_set_text(0, el - 1, ec, el - 1, ec, { "]()" })
  vim.api.nvim_buf_set_text(0, sl - 1, sc - 1, sl - 1, sc - 1, { "[" })
  -- cursor between ( and ) — on the same line only when the wrap was single-line
  local url_line = (sl == el) and sl or el
  local url_col  = ec + ((sl == el) and 1 or 0) + 3
  vim.fn.cursor(url_line, url_col)
  vim.cmd("startinsert")
end


-- gb — toggle a "- " bullet list.
-- Normal mode acts on the current line, visual mode on every selected line.
-- Mixed selections are normalised: if any non-blank line is not a bullet, all
-- of them become bullets; only an all-bullet run is stripped.
-- (Overrides Comment.nvim's blockwise-comment operator.)
local function toggle_list(visual)
  local sl, el
  if visual then
    vim.cmd("normal! \27")
    sl, el = vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
  else
    sl = vim.fn.line(".")
    el = sl
  end

  local lines = vim.api.nvim_buf_get_lines(0, sl - 1, el, false)
  local pat = "^(%s*)[-*+]%s+"

  local all_bullets = true
  local any_content = false
  for _, l in ipairs(lines) do
    if l:match("%S") then
      any_content = true
      if not l:match(pat) then all_bullets = false end
    end
  end
  if not any_content then all_bullets = false end

  for i, l in ipairs(lines) do
    if l:match("%S") then
      if all_bullets then
        lines[i] = l:gsub(pat, "%1", 1)
      elseif not l:match(pat) then
        lines[i] = l:gsub("^(%s*)", "%1- ", 1)
      end
    end
  end

  vim.api.nvim_buf_set_lines(0, sl - 1, el, false, lines)
end

map("n", "gb", function() toggle_list(false) end, "Markdown: toggle bullet list on line")
map("x", "gb", function() toggle_list(true) end, "Markdown: toggle bullet list on selection")


-- <leader>x — add a markdown todo, or toggle the one that is already there.
--
-- All the shapes worth supporting are one grammar: indent, an optional list
-- marker (`- `, `* `, `+ `, `1. `, `1) `), an optional `[ ]`/`[x]` box, then the
-- text. So a single parse covers `[ ] buh`, `- [ ] buh`, `1. [ ] buh` and an
-- indented bullet alike, and the indent and the marker are simply left alone.
--
-- With no box on the line, one is inserted *after* whatever marker is there. A
-- line with no marker at all — prose, or empty — becomes a `- [ ] ` bullet: a
-- bare `[ ] todo` is a shape worth keeping when you have written one, but not
-- one worth creating.
--
-- The toggle has two states, not three: `[ ]` ⇄ `[x]`. Removing a todo is `dd`
-- or an undo, and a three-state cycle makes the common press ambiguous.
local TODO_MARKERS = { "^([-*+]%s+)", "^(%d+[.)]%s+)" }

local function parse_todo(line)
  local indent, rest = line:match("^(%s*)(.*)$")
  local marker
  for _, pat in ipairs(TODO_MARKERS) do
    marker = rest:match(pat)
    if marker then break end
  end
  local body = marker and rest:sub(#marker + 1) or rest
  local box, after = body:match("^(%[[ xX]%])(.*)$")
  return indent, marker, box, after, body
end

-- The rewritten line. `want` is true to check, false to uncheck, nil to flip;
-- a line with no box ignores it and gains an unchecked one.
local function todo_line(line, want)
  local indent, marker, box, after, body = parse_todo(line)
  if not box then
    return indent .. (marker or "- ") .. "[ ] " .. body
  end
  if want == nil then want = box:sub(2, 2) == " " end
  return indent .. (marker or "") .. (want and "[x]" or "[ ]") .. after
end

-- Normal and insert mode act on the current line; visual mode on every
-- non-blank selected line, normalised the way gb normalises a mixed bullet
-- selection: a line without a box gains one, and only an all-boxed run flips.
local function toggle_todo(visual)
  if not visual then
    local l = vim.fn.line(".")
    local old = vim.fn.getline(l)
    local new = todo_line(old, nil)
    vim.api.nvim_buf_set_lines(0, l - 1, l, false, { new })
    -- Keep the cursor on the same character of the text, not the same column.
    local col = vim.api.nvim_win_get_cursor(0)[2] + (#new - #old)
    pcall(vim.api.nvim_win_set_cursor, 0, { l, math.max(math.min(col, #new), 0) })
    return
  end

  vim.cmd("normal! \27")
  local sl, el = vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
  local lines = vim.api.nvim_buf_get_lines(0, sl - 1, el, false)

  local all_boxed, all_checked, any = true, true, false
  for _, l in ipairs(lines) do
    if l:match("%S") then
      any = true
      local _, _, box = parse_todo(l)
      if not box then
        all_boxed = false
      elseif box:sub(2, 2) == " " then
        all_checked = false
      end
    end
  end
  local want = (any and all_boxed) and (not all_checked) or nil

  for i, l in ipairs(lines) do
    if l:match("%S") then
      local _, _, box = parse_todo(l)
      -- In a mixed selection only the boxless lines change: the ones that are
      -- already todos keep whatever state you put them in.
      if box == nil or want ~= nil then lines[i] = todo_line(l, want) end
    end
  end

  vim.api.nvim_buf_set_lines(0, sl - 1, el, false, lines)
end

-- Prose-only maps. These two keys are worth having in markdown but too costly
-- to take globally, so they are scoped instead of overridden:
--   <leader>c  is Comment.nvim's visual line-comment toggle everywhere else
--   <leader>l  is the prefix for <leader>la (Copilot), <leader>lr (Copilot
--              Chat refactor) and <leader>le (LspEnable) — all three are
--              unreachable inside a prose buffer, which is the accepted cost:
--              LSP and Copilot are not markdown concerns
--
-- The autocmd matches FileType "*" rather than the prose list so that a buffer
-- whose filetype *changes away* from markdown gets these maps taken back off;
-- a buffer-local map set once would otherwise outlive the filetype that
-- justified it.
local prose_filetypes = {
  markdown = true, text = true, pandoc = true, quarto = true, rmd = true,
}

-- <leader>x is prose-scoped for the same reason: nothing outside a markdown
-- buffer wants a checkbox.
--
-- It was <C-CR> first, which is the obvious key for this and does not work.
-- <C-CR> is distinct from <CR> only over the kitty keyboard protocol, and
-- although this terminal stack does speak that protocol elsewhere (it is what
-- makes <C-S-w> work in lua/shared/remap.lua), the chord never arrived —
-- verified by hand. So the key is a <leader> one, which also means the mapping
-- is normal and visual mode only: <leader> is a literal backslash in insert.
local prose_maps = {
  { "<leader>c", function(v) toggle_surround("`", "`", v) end, "Markdown: toggle `code`" },
  { "<leader>l", function(v) toggle_link(v) end,               "Markdown: toggle [text](url)" },
  { "<leader>x", function(v) toggle_todo(v) end,               "Markdown: add/toggle a todo" },
}

vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    local prose = prose_filetypes[args.match]
    for _, spec in ipairs(prose_maps) do
      local lhs, fn, desc, modes = spec[1], spec[2], spec[3], spec[4] or { "n", "x" }
      for _, m in ipairs(modes) do
        if prose then
          vim.keymap.set(m, lhs, function() fn(m == "x") end,
            { buffer = args.buf, desc = desc, silent = true })
        else
          pcall(vim.keymap.del, m, lhs, { buffer = args.buf })
        end
      end
    end
  end,
})
