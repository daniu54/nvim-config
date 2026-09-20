-- markdown_format.lua — an opinionated markdown reformatter.
--
-- `M.format(lines)` takes a list of lines and gives back the same document in
-- one canonical shape. It is pure: no buffer, no cursor, no vim state beyond
-- `strdisplaywidth`, which is what makes it testable from a headless nvim (see
-- `scripts/test-markdown-format.lua`). `after/plugin/markdown_format.lua` is
-- the thin :MarkdownFormat wrapper around it.
--
-- **The headline rule is that prose is never wrapped.** A paragraph, a list
-- item, a table cell, a quoted line — each is one line, however long. Hard
-- wrapping is what a generated document arrives with, and it breaks the thing
-- a markdown file is most often used for here: `/\.*cache` finds a phrase only
-- when the phrase is on one line. `set wrap` already draws it wrapped; a
-- newline in the file is a different claim, and mostly a false one.
--
-- This is deliberately *not* what prettier does on save (`after/plugin/
-- conform.lua`, proseWrap defaults to "preserve" — it leaves whatever wrapping
-- it finds, in either direction). The two do not fight: prettier preserves the
-- long lines this produces, and normalises blank lines and tables the same way
-- it does here, so a :w after a :MarkdownFormat is a no-op. It is a separate
-- command rather than a save-time formatter because unwrapping a document is
-- a large, one-way edit — it should happen when you ask for it.
--
-- What it guarantees:
--
--   * one blank line between blocks, and after every heading; never two
--   * setext headings (`===` / `---` underlines) become `#` / `##`
--   * `*` and `+` bullets become `-`; ordered lists are renumbered 1..n per
--     list and per nesting level; nesting is re-indented to the parent's
--     content column
--   * tables are padded to even columns, honouring the alignment colons
--   * `***` / `___` thematic breaks become `---`
--   * trailing whitespace goes, except a two-space hard break, which is kept
--     as exactly two
--   * the file ends in exactly one newline and starts with no blank lines
--
-- What it will not touch, because the bytes are the content:
--
--   * fenced code blocks, and indented (4-space) code blocks
--   * YAML front matter
--   * raw HTML blocks
--   * link reference definitions (`[id]: url`)
--   * mdpdf directives (`/comment`, `/ignore`, `/title`, …) — each keeps its
--     own line and is never joined into the paragraph under it

local M = {}

-- ---------------------------------------------------------------------------
-- line classification
-- ---------------------------------------------------------------------------

local function is_blank(line)
  return line:match('^%s*$') ~= nil
end

local function indent_of(line)
  local spaces = line:match('^[ \t]*')
  -- A tab is an indent of 4 here, which is the CommonMark tab stop and also
  -- the only reading under which "indented code" means anything consistent.
  local n = 0
  for c in spaces:gmatch('.') do
    n = n + (c == '\t' and 4 or 1)
  end
  return n
end

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- mdpdf's line directives (see after/plugin/markdown_convert.lua). Each one
-- owns its line: `/comment note` sitting above a paragraph must not be swept
-- into it by the unwrapper, which would turn the whole paragraph into a
-- comment and drop it from the export.
local DIRECTIVES = {
  comment = true,
  ignore = true,
  endignore = true,
  title = true,
  newpage = true,
  pagebreak = true,
  newline = true,
  blankline = true,
  toc = true,
  tableofcontents = true,
}

local function is_directive(line)
  local word = line:match('^/(%a+)')
  return word ~= nil and DIRECTIVES[word:lower()] == true
end

-- A pandoc attribute block alone on its line: `{#the-spot}`, `{.notoc}`.
local function is_attr_line(line)
  return line:match('^%s*%b{}%s*$') ~= nil and line:match('{%s*[#%.]') ~= nil
end

-- `[id]: https://example.com "title"`
local function is_refdef(line)
  return line:match('^ ? ? ?%[[^%]]+%]:%s') ~= nil
end

local function fence_open(line)
  if indent_of(line) > 3 then
    return nil
  end
  local run = line:match('^%s*(`+)') or line:match('^%s*(~+)')
  if not run or #run < 3 then
    return nil
  end
  local info = line:match('^%s*' .. run:sub(1, 1) .. '+(.*)$') or ''
  -- A backtick fence's info string may not itself contain a backtick; that is
  -- how ``a `b` c`` inline code is kept from opening a block.
  if run:sub(1, 1) == '`' and info:find('`') then
    return nil
  end
  return { char = run:sub(1, 1), len = #run, info = trim(info) }
end

local function fence_close(line, fence)
  local run = line:match('^%s*(' .. (fence.char == '`' and '`' or '~') .. '+)%s*$')
  return run ~= nil and #run >= fence.len
end

local function thematic_break(line)
  if indent_of(line) > 3 then
    return false
  end
  local body = line:gsub('%s', '')
  if #body < 3 then
    return false
  end
  return body:match('^%-+$') ~= nil or body:match('^%*+$') ~= nil or body:match('^_+$') ~= nil
end

-- An ATX heading -> level, text. The closing hashes of `## Title ##` are
-- dropped; `## C#` keeps its hash, since the rule needs whitespace in front.
local function atx_heading(line)
  if indent_of(line) > 3 then
    return nil
  end
  local hashes, rest = line:match('^%s*(#+)%s(.*)$')
  if not hashes then
    hashes = line:match('^%s*(#+)%s*$')
    rest = ''
  end
  if not hashes or #hashes > 6 then
    return nil
  end
  rest = trim(rest):gsub('%s+#+$', '')
  return #hashes, trim(rest)
end

local function setext_underline(line)
  if indent_of(line) > 3 then
    return nil
  end
  local body = trim(line)
  if body:match('^=+$') then
    return 1
  end
  if body:match('^%-+$') then
    return 2
  end
  return nil
end

local function html_block_start(line)
  return indent_of(line) <= 3 and line:match('^%s*<[%a!/?]') ~= nil
end

local function blockquote_strip(line)
  if indent_of(line) > 3 then
    return nil
  end
  local rest = line:match('^%s*>%s?(.*)$')
  return rest
end

-- A list item -> its indent, marker kind and the text after the marker.
-- Checked *after* thematic_break, so `- - -` is a rule and not an item.
local function list_item(line)
  local spaces, bullet, text = line:match('^([ \t]*)([%-%*%+])[ \t]+(.*)$')
  if bullet then
    return { indent = indent_of(line), marker = '-', width = 1, text = text }
  end
  spaces, bullet = line:match('^([ \t]*)([%-%*%+])[ \t]*$')
  if bullet then
    return { indent = indent_of(line), marker = '-', width = 1, text = '' }
  end
  local num, delim
  spaces, num, delim, text = line:match('^([ \t]*)(%d+)([%.%)])[ \t]+(.*)$')
  if num then
    return { indent = indent_of(line), ordered = true, delim = delim, width = #num + 1, text = text }
  end
  spaces, num, delim = line:match('^([ \t]*)(%d+)([%.%)])[ \t]*$')
  if num then
    return { indent = indent_of(line), ordered = true, delim = delim, width = #num + 1, text = '' }
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------------

-- Split a row on unescaped pipes. `\|` comes back as a literal `|` in the
-- cell and is re-escaped on render, so the round trip is lossless.
local function split_row(line)
  local body = trim(line):gsub('^|', ''):gsub('|$', '')
  local cells, cur, i = {}, {}, 1
  while i <= #body do
    local c = body:sub(i, i)
    if c == '\\' and body:sub(i + 1, i + 1) == '|' then
      cur[#cur + 1] = '|'
      i = i + 2
    elseif c == '|' then
      cells[#cells + 1] = trim(table.concat(cur))
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
      i = i + 1
    end
  end
  cells[#cells + 1] = trim(table.concat(cur))
  return cells
end

local function is_delimiter_row(line)
  if not line or not line:find('|') or not line:find('[-:]') then
    return false
  end
  local cells = split_row(line)
  if #cells == 0 then
    return false
  end
  for _, cell in ipairs(cells) do
    if not cell:match('^:?%-%-*:?$') then
      return false
    end
  end
  return true
end

local function alignments_of(line)
  local out = {}
  for _, cell in ipairs(split_row(line)) do
    local left, right = cell:sub(1, 1) == ':', cell:sub(-1) == ':'
    out[#out + 1] = (left and right and 'center') or (right and 'right') or (left and 'left') or 'none'
  end
  return out
end

local function display_width(s)
  return vim.fn.strdisplaywidth(s)
end

local function pad_cell(text, width, align)
  local slack = width - display_width(text)
  if slack <= 0 then
    return text
  end
  if align == 'right' then
    return string.rep(' ', slack) .. text
  end
  if align == 'center' then
    local left = math.floor(slack / 2)
    return string.rep(' ', left) .. text .. string.rep(' ', slack - left)
  end
  return text .. string.rep(' ', slack)
end

local function render_table(rows, aligns)
  local ncols = #aligns
  for _, row in ipairs(rows) do
    ncols = math.max(ncols, #row)
  end

  local widths = {}
  for c = 1, ncols do
    -- 3 is the narrowest a delimiter cell can be and still read as one.
    widths[c] = 3
    for _, row in ipairs(rows) do
      local cell = (row[c] or ''):gsub('|', '\\|')
      widths[c] = math.max(widths[c], display_width(cell))
    end
  end

  local function line_of(cells)
    local out = {}
    for c = 1, ncols do
      out[c] = pad_cell((cells[c] or ''):gsub('|', '\\|'), widths[c], aligns[c] or 'none')
    end
    return '| ' .. table.concat(out, ' | ') .. ' |'
  end

  local out = { line_of(rows[1] or {}) }

  local delim = {}
  for c = 1, ncols do
    local w, a = widths[c], aligns[c] or 'none'
    if a == 'center' then
      delim[c] = ':' .. string.rep('-', w - 2) .. ':'
    elseif a == 'right' then
      delim[c] = string.rep('-', w - 1) .. ':'
    elseif a == 'left' then
      delim[c] = ':' .. string.rep('-', w - 1)
    else
      delim[c] = string.rep('-', w)
    end
  end
  out[#out + 1] = '| ' .. table.concat(delim, ' | ') .. ' |'

  for r = 2, #rows do
    out[#out + 1] = line_of(rows[r])
  end
  return out
end

-- ---------------------------------------------------------------------------
-- unwrapping prose
-- ---------------------------------------------------------------------------

-- Join a run of prose lines into one, stopping only at an explicit hard break:
-- a line ending in two-or-more spaces, or in a backslash. Those are the one
-- way a markdown author asks for a newline *inside* a paragraph, so they are
-- the one kind of line break that survives. Trailing whitespace is normalised
-- to exactly two spaces, since three is the same break spelled sloppily.
local function join_prose(src)
  local out, cur = {}, {}
  for idx, raw in ipairs(src) do
    local hard_space = raw:match('%S%s%s+$') ~= nil
    local body = trim(raw)
    local hard_slash = body:match('\\$') ~= nil
    cur[#cur + 1] = body
    local last = idx == #src
    if last then
      out[#out + 1] = table.concat(cur, ' ')
      cur = {}
    elseif hard_space then
      out[#out + 1] = table.concat(cur, ' ') .. '  '
      cur = {}
    elseif hard_slash then
      out[#out + 1] = table.concat(cur, ' ')
      cur = {}
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- the block scanner
-- ---------------------------------------------------------------------------

-- format_blocks is recursive: a list item's content and a blockquote's body
-- are dedented and fed back through it, which is how a nested list, a fenced
-- block inside a bullet, or a quoted table all come out right with no special
-- case for each. `depth` only guards against a pathological document.
local format_blocks

-- Trailing whitespace goes, with one exception: exactly two spaces is a hard
-- line break, the one piece of markdown whose whole meaning is trailing
-- whitespace. Stripping it here is what made the formatter non-idempotent —
-- the break survived the first pass and the second pass then joined the two
-- lines, because the thing marking them as separate had been rubbed out.
local function rstrip(line)
  if line:match('%S  $') then
    return line
  end
  return (line:gsub('%s+$', ''))
end

local function emit_verbatim(out, lines)
  for _, l in ipairs(lines) do
    out[#out + 1] = rstrip(l)
  end
end

-- Two items belong to the same list only if they are marked the same way.
-- `*` / `+` / `-` all normalise to `-` so switching between those is not a
-- boundary, but a bullet list followed by an ordered one is two lists, and so
-- is `1.` followed by `1)` — otherwise the renumbering would run straight
-- through from one into the next.
local function item_kind(item)
  return item.ordered and ('ordered' .. item.delim) or 'bullet'
end

-- The run of lines belonging to one list, from its first item to the first
-- line that is neither an item of the same kind, nor indented under one, nor
-- a blank between two of those.
local function list_extent(lines, start)
  local head = list_item(lines[start])
  local base, kind = head.indent, item_kind(head)
  local i = start + 1
  local last = start
  while i <= #lines do
    local line = lines[i]
    if is_blank(line) then
      i = i + 1
    elseif indent_of(line) > base and not thematic_break(line) then
      last = i
      i = i + 1
    else
      local item = list_item(line)
      if item and not thematic_break(line) and item.indent >= base and item_kind(item) == kind then
        last = i
        i = i + 1
      else
        break
      end
    end
  end
  return last
end

-- Strip the common indent off an item's continuation lines so the recursion
-- sees them at column 0. Capped at the item's own content column: a line
-- indented further than that is nested structure and must keep the difference.
local function dedent(lines, cap)
  local min
  for _, l in ipairs(lines) do
    if not is_blank(l) then
      local n = indent_of(l)
      if not min or n < min then
        min = n
      end
    end
  end
  min = math.min(min or 0, cap)
  local out = {}
  for idx, l in ipairs(lines) do
    if is_blank(l) then
      out[idx] = ''
    else
      local removed, rest = 0, l
      while removed < min do
        local c = rest:sub(1, 1)
        if c == ' ' then
          removed, rest = removed + 1, rest:sub(2)
        elseif c == '\t' then
          removed, rest = removed + 4, rest:sub(2)
        else
          break
        end
      end
      out[idx] = string.rep(' ', math.max(0, removed - min)) .. rest
    end
  end
  return out
end

local function format_list(lines, first, last, depth)
  local head = list_item(lines[first])
  local base, kind = head.indent, item_kind(head)

  -- Cut the run into items: an item starts at a list marker sitting at the
  -- list's own indent, and owns everything up to the next one.
  local items, loose = {}, false
  local i = first
  while i <= last do
    local item = list_item(lines[i])
    if item and item.indent <= base and not thematic_break(lines[i]) and item_kind(item) == kind then
      items[#items + 1] = { head = item, body = {}, at = i }
    elseif #items > 0 then
      local cur = items[#items]
      cur.body[#cur.body + 1] = lines[i]
    end
    i = i + 1
  end

  -- A list is loose when a blank line separates two of its items; that blank
  -- is meaningful (it wraps each item in a <p>), so it is preserved for the
  -- whole list rather than per item.
  for n = 2, #items do
    local prev = items[n].at - 1
    if prev >= first and is_blank(lines[prev]) then
      loose = true
    end
  end

  local out = {}
  local number = 0
  for n, item in ipairs(items) do
    number = number + 1
    local marker
    if item.head.ordered then
      -- Renumbered 1..n rather than left as written: a generated list is
      -- often all `1.`, and a hand-edited one is often 1,2,2,3.
      marker = tostring(number) .. item.head.delim
    else
      marker = '-'
    end
    local content_col = #marker + 1

    -- Trailing blank lines belong between items, not inside one.
    local body = item.body
    while #body > 0 and is_blank(body[#body]) do
      table.remove(body)
    end

    local src = { item.head.text }
    vim.list_extend(src, dedent(body, base + item.head.width + 1))

    local rendered = format_blocks(src, depth + 1, true)
    if #rendered == 0 then
      rendered = { '' }
    end

    if n > 1 and loose then
      out[#out + 1] = ''
    end
    out[#out + 1] = (marker .. ' ' .. rendered[1]):gsub('%s+$', '')
    for k = 2, #rendered do
      out[#out + 1] = rendered[k] == '' and '' or (string.rep(' ', content_col) .. rendered[k])
    end
  end
  return out
end

-- `tight` is set for the content of a list item, and it changes exactly one
-- thing: a blank line between two blocks is emitted only where the source had
-- one. Everywhere else a blank between blocks is forced, which is the whole
-- point of the command — but inside a list item a blank line is not cosmetic.
-- `- a` / `  - b` is a tight list; putting a blank between them makes the
-- outer list loose and every item of it grows a <p>. A heading still gets its
-- blank line, tight or not.
format_blocks = function(lines, depth, tight)
  local out = {}
  local pending_blank, prev_heading = false, false
  local function sep()
    if #out == 0 then
      return
    end
    if tight and not pending_blank and not prev_heading then
      return
    end
    out[#out + 1] = ''
  end

  if depth > 12 then
    emit_verbatim(out, lines)
    return out
  end

  local i = 1

  -- YAML front matter, but only as the very first line of the document.
  if lines[1] and trim(lines[1]) == '---' then
    local close
    for n = 2, #lines do
      if trim(lines[n]) == '---' then
        close = n
        break
      end
    end
    if close then
      for n = 1, close do
        out[#out + 1] = (lines[n]:gsub('%s+$', ''))
      end
      i = close + 1
    end
  end

  while i <= #lines do
    local line = lines[i]
    local this_heading = false

    if is_blank(line) then
      pending_blank = true
      i = i + 1

    -- fenced code: verbatim, including an unterminated one (a range that cuts
    -- a fence in half must not have its tail reflowed as prose)
    elseif fence_open(line) then
      local fence = fence_open(line)
      local chunk = { (line:gsub('%s+$', '')) }
      i = i + 1
      while i <= #lines do
        chunk[#chunk + 1] = lines[i]
        local closed = fence_close(lines[i], fence)
        i = i + 1
        if closed then
          break
        end
      end
      sep()
      emit_verbatim(out, chunk)

    elseif thematic_break(line) then
      sep()
      out[#out + 1] = '---'
      i = i + 1

    elseif atx_heading(line) then
      local level, text = atx_heading(line)
      sep()
      out[#out + 1] = text == '' and string.rep('#', level) or (string.rep('#', level) .. ' ' .. text)
      this_heading = true
      i = i + 1

    elseif is_directive(line) then
      -- A run of directives stays a run: three `/newline`s really are three.
      sep()
      while i <= #lines and is_directive(lines[i]) do
        out[#out + 1] = (lines[i]:gsub('%s+$', ''))
        i = i + 1
      end

    elseif is_attr_line(line) then
      sep()
      out[#out + 1] = trim(line)
      i = i + 1

    elseif is_refdef(line) then
      sep()
      while i <= #lines and is_refdef(lines[i]) do
        out[#out + 1] = trim(lines[i])
        i = i + 1
      end

    elseif is_delimiter_row(lines[i + 1] or '') and line:find('|') then
      local header = split_row(line)
      local aligns = alignments_of(lines[i + 1])
      local rows = { header }
      i = i + 2
      while i <= #lines and not is_blank(lines[i]) and lines[i]:find('|') do
        rows[#rows + 1] = split_row(lines[i])
        i = i + 1
      end
      sep()
      emit_verbatim(out, render_table(rows, aligns))

    elseif blockquote_strip(line) then
      local body = {}
      while i <= #lines do
        local stripped = blockquote_strip(lines[i])
        if stripped then
          body[#body + 1] = stripped
        elseif not is_blank(lines[i]) and #body > 0 and not is_blank(body[#body]) then
          body[#body + 1] = lines[i] -- lazy continuation
        else
          break
        end
        i = i + 1
      end
      sep()
      for _, l in ipairs(format_blocks(body, depth + 1)) do
        out[#out + 1] = l == '' and '>' or ('> ' .. l)
      end

    elseif list_item(line) then
      local last = list_extent(lines, i)
      sep()
      emit_verbatim(out, format_list(lines, i, last, depth))
      i = last + 1

    elseif html_block_start(line) then
      local chunk = {}
      while i <= #lines and not is_blank(lines[i]) do
        chunk[#chunk + 1] = lines[i]
        i = i + 1
      end
      sep()
      emit_verbatim(out, chunk)

    elseif indent_of(line) >= 4 then
      -- An indented code block. CommonMark's rule, applied literally: four
      -- spaces at the start of a block is code even when it looks like a
      -- list, because that is how it renders.
      local chunk = {}
      while i <= #lines and (is_blank(lines[i]) or indent_of(lines[i]) >= 4) do
        chunk[#chunk + 1] = lines[i]
        i = i + 1
      end
      while #chunk > 0 and is_blank(chunk[#chunk]) do
        table.remove(chunk)
      end
      sep()
      emit_verbatim(out, chunk)

    else
      -- A paragraph, up to the first line that starts something else.
      local chunk = {}
      local heading_level
      while i <= #lines do
        local l = lines[i]
        if is_blank(l) then
          break
        end
        local level = setext_underline(l)
        if level and #chunk > 0 then
          -- `---` under a paragraph is a setext h2, not a rule; CommonMark is
          -- explicit about it, and it is the only reading that keeps the
          -- rendering the same.
          heading_level = level
          i = i + 1
          break
        end
        if
          #chunk > 0
          and (
            fence_open(l)
            or thematic_break(l)
            or atx_heading(l)
            or is_directive(l)
            or is_refdef(l)
            or is_attr_line(l)
            or list_item(l)
            or blockquote_strip(l)
            or html_block_start(l)
            or is_delimiter_row(lines[i + 1] or '') and l:find('|')
          )
        then
          break
        end
        chunk[#chunk + 1] = l
        i = i + 1
      end
      sep()
      if heading_level then
        out[#out + 1] = string.rep('#', heading_level) .. ' ' .. trim(table.concat(chunk, ' '))
        this_heading = true
      else
        emit_verbatim(out, join_prose(chunk))
      end
    end

    if not is_blank(line) then
      pending_blank = false
      prev_heading = this_heading
    end
  end

  return out
end

-- ---------------------------------------------------------------------------
-- public
-- ---------------------------------------------------------------------------

--- Reformat a markdown document.
--- @param lines string[] the document, one string per line
--- @return string[] the reformatted document
function M.format(lines)
  local out = format_blocks(lines, 0)
  -- No leading blank, no trailing run of them. The caller writes the buffer,
  -- so the single trailing newline is nvim's 'eol', not a line here.
  while #out > 0 and out[#out] == '' do
    table.remove(out)
  end
  return out
end

return M
