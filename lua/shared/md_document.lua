-- md_document.lua — markdown -> a typed block list, plus the style loader.
--
-- The consumer is :ExportToExcalidraw (after/plugin/markdown_excalidraw.lua),
-- which hands the block list to the local Excalidraw app; the app turns each
-- block into canvas elements. Everything that can be decided by reading the
-- text happens here; everything that needs a DOM (measuring a string, laying
-- out mermaid, an image's intrinsic size) happens there.
--
-- The dialect is the one mdpdf accepts (see markdown_convert.lua), so a
-- document written for :ConvertToPdf exports to a canvas without edits:
-- /title, /comment, /ignore../endignore, /newline, /toc, `{#id}`/`{.notoc}`
-- heading attributes and the `#anchor Heading` fence line are all understood.
-- /newpage is parsed and dropped — a canvas has no pages.

local M = {}

-- ---------------------------------------------------------------------------
-- inline markdown
-- ---------------------------------------------------------------------------

-- An Excalidraw text element has one font and one colour for the whole string,
-- so inline emphasis cannot survive as emphasis. It is stripped rather than
-- left in: `**deadline**` reads as a word with asterisks stuck to it, which is
-- worse than losing the bold.
function M.inline_text(s)
  s = s:gsub("!%[([^%]]*)%]%b()", "%1") -- image -> its alt text
  s = s:gsub("%[([^%]]*)%]%b()", "%1") -- link  -> its label
  s = s:gsub("%[([^%]]*)%]%[[^%]]*%]", "%1") -- reference link
  s = s:gsub("<(https?://[^>]+)>", "%1")
  s = s:gsub("`+([^`]*)`+", "%1")
  s = s:gsub("%*%*%*(.-)%*%*%*", "%1")
  s = s:gsub("%*%*(.-)%*%*", "%1")
  s = s:gsub("%*(.-)%*", "%1")
  s = s:gsub("~~(.-)~~", "%1")
  s = s:gsub("(%W)_([^_]+)_(%W)", "%1%2%3")
  s = s:gsub("^_([^_]+)_$", "%1")
  s = s:gsub("<br%s*/?>", " ")
  s = s:gsub("\\([%*_`~%[%]])", "%1") -- escaped punctuation keeps the character
  return s
end

-- first_link returns the single URL a line points at, if it is the only one.
-- Excalidraw can hang a link off an element, so a bullet that is just a link
-- stays clickable even though inline links cannot.
local function first_link(s)
  local url = s:match("%[[^%]]*%]%((%S-)%)")
  if not url then
    url = s:match("^%s*<(https?://[^>]+)>%s*$") or s:match("^%s*(https?://%S+)%s*$")
  end
  if url and url ~= "" and not url:match("^#") then
    return url
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- block parser
-- ---------------------------------------------------------------------------

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

local function is_hr(line)
  local body = line:gsub("%s", "")
  return #body >= 3 and (body:match("^%-+$") or body:match("^%*+$") or body:match("^_+$")) ~= nil
end

-- A table delimiter row: |---|:--:| . The pipes are optional at the edges.
local function is_table_delimiter(line)
  if not line:match("[-:]") then
    return false
  end
  local body = vim.trim(line):gsub("^|", ""):gsub("|$", "")
  if body == "" then
    return false
  end
  for cell in (body .. "|"):gmatch("(.-)|") do
    if not vim.trim(cell):match("^:?%-%-*:?$") then
      return false
    end
  end
  return true
end

local function split_row(line)
  local body = vim.trim(line):gsub("^|", ""):gsub("|$", "")
  local cells = {}
  -- Split on unescaped pipes so `a \| b` stays one cell.
  local cur = {}
  local i = 1
  while i <= #body do
    local c = body:sub(i, i)
    if c == "\\" and body:sub(i + 1, i + 1) == "|" then
      table.insert(cur, "|")
      i = i + 2
    elseif c == "|" then
      table.insert(cells, vim.trim(table.concat(cur)))
      cur = {}
      i = i + 1
    else
      table.insert(cur, c)
      i = i + 1
    end
  end
  table.insert(cells, vim.trim(table.concat(cur)))
  return cells
end

local function alignments(delim)
  local out = {}
  for _, cell in ipairs(split_row(delim)) do
    local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
    out[#out + 1] = (left and right and "center") or (right and "right") or "left"
  end
  return out
end

-- Heading attributes: `## Title {#anchor}` / `{.notoc}`.
local function strip_heading_attrs(text)
  local id, notoc
  text = text:gsub("%s*{([^}]*)}%s*$", function(attrs)
    id = attrs:match("#([%w_%-%.]+)")
    notoc = attrs:match("%.notoc") ~= nil
    return ""
  end)
  return vim.trim(text), id, notoc
end

-- expand_tabs keeps code columns predictable: Excalidraw turns a tab into
-- eight spaces at measure time, which is never what the source meant.
local function expand_tabs(s, width)
  width = width or 4
  local out, col = {}, 0
  for ch in s:gmatch(".") do
    if ch == "\t" then
      local n = width - (col % width)
      table.insert(out, string.rep(" ", n))
      col = col + n
    else
      table.insert(out, ch)
      col = col + 1
    end
  end
  return table.concat(out)
end

-- parse turns buffer lines into blocks. Returns `blocks, meta` where meta
-- carries the document title and the heading list a /toc is built from.
function M.parse(lines)
  local blocks = {}
  local meta = { title = nil, headings = {} }

  local para = {}
  local list = nil

  local function flush_para()
    if #para > 0 then
      local text = table.concat(para, " ")
      blocks[#blocks + 1] = {
        type = "paragraph",
        text = M.inline_text(text),
        link = first_link(text),
      }
      para = {}
    end
  end

  local function flush_list()
    if list then
      blocks[#blocks + 1] = list
      list = nil
    end
  end

  local function flush()
    flush_para()
    flush_list()
  end

  local i = 1

  -- YAML front matter is metadata for some other tool; it is not content.
  if lines[1] and vim.trim(lines[1]) == "---" then
    local j = 2
    while j <= #lines and vim.trim(lines[j]) ~= "---" do
      j = j + 1
    end
    if j <= #lines then
      i = j + 1
    end
  end

  while i <= #lines do
    local line = lines[i]
    local trimmed = vim.trim(line)

    -- --- mdpdf directives ---------------------------------------------------
    local directive = trimmed:match("^/(%a+)")
    if directive then
      directive = directive:lower()
      if directive == "comment" then
        i = i + 1
        goto continue
      elseif directive == "ignore" then
        -- An /ignore with no /endignore drops the rest of the file. That is the
        -- documented reading: a finished document on top, a scratchpad below.
        flush()
        local j = i + 1
        while j <= #lines and not vim.trim(lines[j]):match("^/endignore") do
          j = j + 1
        end
        i = j + 1
        goto continue
      elseif directive == "endignore" then
        i = i + 1
        goto continue
      elseif directive == "title" then
        flush()
        local text = vim.trim(trimmed:sub(7))
        meta.title = M.inline_text(text)
        blocks[#blocks + 1] = { type = "title", text = meta.title }
        i = i + 1
        goto continue
      elseif directive == "newpage" or directive == "pagebreak" then
        -- A canvas has no pages. Kept as a parse case so the directive is
        -- dropped rather than rendered as a stray "/newpage" paragraph.
        flush()
        i = i + 1
        goto continue
      elseif directive == "newline" or directive == "blankline" then
        flush()
        blocks[#blocks + 1] = { type = "spacer" }
        i = i + 1
        goto continue
      elseif directive == "toc" or directive == "tableofcontents" then
        flush()
        blocks[#blocks + 1] = { type = "toc" }
        i = i + 1
        goto continue
      end
    end

    -- --- fenced code / mermaid ---------------------------------------------
    local indent, ticks, info = line:match("^(%s*)(```+)%s*(.-)%s*$")
    if not ticks then
      indent, ticks, info = line:match("^(%s*)(~~~+)%s*(.-)%s*$")
    end
    if ticks then
      flush()
      local lang = info and info:match("^([%w_+#%-%.]+)") or nil
      local rest = info and info:sub(#(lang or "") + 1) or ""
      local anchor = rest:match("#([%w_%-%.]+)")
      if anchor then
        rest = rest:gsub("#" .. anchor, "", 1)
      end
      local attrs = rest:match("{(.-)}")
      if attrs then
        rest = rest:gsub("{.-}", "", 1)
      end
      local heading = vim.trim(rest)

      local body = {}
      local j = i + 1
      while j <= #lines do
        local close = lines[j]:match("^%s*(```+)%s*$") or lines[j]:match("^%s*(~~~+)%s*$")
        if close and #close >= #ticks then
          break
        end
        local stripped = lines[j]
        if indent ~= "" then
          stripped = stripped:gsub("^" .. indent, "")
        end
        table.insert(body, expand_tabs(stripped))
        j = j + 1
      end
      i = j + 1

      local code = table.concat(body, "\n")
      if lang and lang:lower() == "mermaid" then
        if vim.trim(code) ~= "" then
          blocks[#blocks + 1] = { type = "mermaid", code = vim.trim(code), heading = heading ~= "" and heading or nil }
        end
      else
        blocks[#blocks + 1] = {
          type = "code",
          lang = lang,
          heading = heading ~= "" and heading or nil,
          lines = body,
          numbered = not (attrs or ""):match("%.nolinenumbers"),
        }
      end
      goto continue
    end

    -- --- blank -------------------------------------------------------------
    if is_blank(line) then
      flush()
      i = i + 1
      goto continue
    end

    -- --- heading -----------------------------------------------------------
    local hashes, htext = trimmed:match("^(#+)%s+(.*)$")
    if hashes then
      flush()
      local text, id, notoc = strip_heading_attrs(htext)
      local block = {
        type = "heading",
        level = math.min(#hashes, 6),
        text = M.inline_text(text),
        id = id,
      }
      blocks[#blocks + 1] = block
      if not notoc then
        table.insert(meta.headings, { level = block.level, text = block.text })
      end
      i = i + 1
      goto continue
    end

    -- --- horizontal rule ---------------------------------------------------
    if is_hr(trimmed) then
      flush()
      blocks[#blocks + 1] = { type = "rule" }
      i = i + 1
      goto continue
    end

    -- --- table -------------------------------------------------------------
    if trimmed:match("^|") and lines[i + 1] and is_table_delimiter(lines[i + 1]) then
      flush()
      local header = split_row(line)
      local align = alignments(lines[i + 1])
      local rows = {}
      local j = i + 2
      while j <= #lines and vim.trim(lines[j]):match("^|") do
        table.insert(rows, split_row(lines[j]))
        j = j + 1
      end
      for _, row in ipairs(rows) do
        for k, cell in ipairs(row) do
          row[k] = M.inline_text(cell)
        end
      end
      for k, cell in ipairs(header) do
        header[k] = M.inline_text(cell)
      end
      blocks[#blocks + 1] = { type = "table", header = header, align = align, rows = rows }
      i = j
      goto continue
    end

    -- --- blockquote --------------------------------------------------------
    if trimmed:match("^>") then
      flush()
      local quoted = {}
      local j = i
      while j <= #lines and vim.trim(lines[j]):match("^>") do
        table.insert(quoted, vim.trim(vim.trim(lines[j]):gsub("^>%s?", "")))
        j = j + 1
      end
      blocks[#blocks + 1] = {
        type = "quote",
        text = M.inline_text(vim.trim(table.concat(quoted, " "))),
      }
      i = j
      goto continue
    end

    -- --- standalone image --------------------------------------------------
    -- Only a line that is nothing but an image becomes an image element; an
    -- image sitting inside a sentence stays as its alt text, because there is
    -- no way to flow a picture through a line of Excalidraw text.
    local alt, src = trimmed:match("^!%[([^%]]*)%]%((%S+)%)$")
    if not src then
      alt, src = trimmed:match("^!%[([^%]]*)%]%((%S+)%s+\"[^\"]*\"%)$")
    end
    if src then
      flush()
      blocks[#blocks + 1] = { type = "image", alt = M.inline_text(alt or ""), src = src }
      i = i + 1
      goto continue
    end

    -- --- list --------------------------------------------------------------
    local lindent, bullet, ltext = line:match("^(%s*)([%-%*%+])%s+(.*)$")
    local number
    if not bullet then
      lindent, number, ltext = line:match("^(%s*)(%d+)[%.%)]%s+(.*)$")
    end
    if bullet or number then
      flush_para()
      local depth = math.floor(#(lindent or "") / 2)
      if not list then
        list = { type = "list", items = {} }
      end
      local checked = nil
      local box, rest = ltext:match("^%[([ xX])%]%s+(.*)$")
      if box then
        checked = box:lower() == "x"
        ltext = rest
      end
      table.insert(list.items, {
        depth = depth,
        ordered = number ~= nil,
        number = number and tonumber(number) or nil,
        checked = checked,
        text = M.inline_text(ltext),
        link = first_link(ltext),
      })
      i = i + 1
      goto continue
    end

    -- A continuation line indented under the last bullet belongs to it.
    if list and line:match("^%s%s+%S") then
      local last = list.items[#list.items]
      last.text = last.text .. " " .. M.inline_text(trimmed)
      i = i + 1
      goto continue
    end

    -- --- paragraph ---------------------------------------------------------
    flush_list()
    table.insert(para, trimmed)
    i = i + 1

    ::continue::
  end

  flush()
  return blocks, meta
end

-- ---------------------------------------------------------------------------
-- code highlighting
-- ---------------------------------------------------------------------------
--
-- Excalidraw text carries one colour per element, so a highlighted code block
-- is one text element per coloured run. The runs are produced here, by the same
-- treesitter queries the editor highlights the buffer with, and named by capture
-- (`@keyword.function`); the style file maps a capture to a colour. That keeps
-- the colours in the style file rather than pinned to whatever colorscheme
-- happened to be active at export time.

-- Fence languages are written the way file extensions are (`js`, `ps1`, `yml`);
-- parsers are named after filetypes. Try the alias table, then vim's own
-- filetype detection on a fake filename, then the word itself.
local LANG_ALIASES = {
  js = "javascript",
  jsx = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  ts = "typescript",
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  ps1 = "powershell",
  cs = "c_sharp",
  ["c#"] = "c_sharp",
  ["c++"] = "cpp",
  h = "c",
  hpp = "cpp",
  yml = "yaml",
  py = "python",
  rb = "ruby",
  rs = "rust",
  kt = "kotlin",
  htm = "html",
  md = "markdown",
  tex = "latex",
  docker = "dockerfile",
  golang = "go",
  plaintext = nil,
  text = nil,
}

-- Captures that carry no colour of their own. @spell in particular is attached
-- *on top of* comments and strings by most queries, so letting it win would
-- repaint every comment in the default colour.
local SKIP_CAPTURES = {
  spell = true,
  nospell = true,
  conceal = true,
  none = true,
}

function M.resolve_lang(lang)
  if not lang or lang == "" then
    return nil
  end
  lang = lang:lower()
  local candidates = {}
  if LANG_ALIASES[lang] then
    table.insert(candidates, LANG_ALIASES[lang])
  end
  local ft = vim.filetype.match({ filename = "x." .. lang })
  if ft then
    local ok, l = pcall(vim.treesitter.language.get_lang, ft)
    if ok and l then
      table.insert(candidates, l)
    end
  end
  local ok, l = pcall(vim.treesitter.language.get_lang, lang)
  if ok and l then
    table.insert(candidates, l)
  end
  table.insert(candidates, lang)

  for _, cand in ipairs(candidates) do
    if pcall(vim.treesitter.language.add, cand) then
      return cand
    end
  end
  return nil
end

-- highlight_code returns one list of { text, capture } runs per input line.
-- With no parser for the language (or none installed) every line comes back as
-- a single uncaptured run, which the app renders in the default code colour —
-- the documented fallback, not an error.
function M.highlight_code(lines, lang)
  local plain = {}
  for idx, line in ipairs(lines) do
    plain[idx] = { { text = line } }
  end

  local ts_lang = M.resolve_lang(lang)
  if not ts_lang then
    return plain, nil
  end

  local source = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, ts_lang)
  if not ok or not parser then
    return plain, nil
  end

  -- One capture name per byte of each line. Later captures win, which is how
  -- nvim resolves overlapping matches in practice (a bare @variable under a
  -- more specific @function.call).
  local paint = {}
  for idx, line in ipairs(lines) do
    paint[idx] = {}
    for b = 1, #line do
      paint[idx][b] = false
    end
  end

  local ok_parse = pcall(function()
    parser:parse(true)
  end)
  if not ok_parse then
    return plain, ts_lang
  end

  parser:for_each_tree(function(tree, ltree)
    local lang_name = ltree:lang()
    local query = vim.treesitter.query.get(lang_name, "highlights")
    if not query then
      return
    end
    for id, node in query:iter_captures(tree:root(), source) do
      local name = query.captures[id]
      if name and not name:match("^_") and not SKIP_CAPTURES[name] then
        local srow, scol, erow, ecol = node:range()
        for row = srow, erow do
          local li = row + 1
          local target = paint[li]
          if target then
            local from = (row == srow) and scol + 1 or 1
            local to = (row == erow) and ecol or #lines[li]
            for b = from, math.min(to, #lines[li]) do
              target[b] = name
            end
          end
        end
      end
    end
  end)

  local out = {}
  for idx, line in ipairs(lines) do
    local runs = {}
    local start, current = 1, nil
    for b = 1, #line do
      local cap = paint[idx][b]
      if b == 1 then
        current = cap
      elseif cap ~= current then
        runs[#runs + 1] = { text = line:sub(start, b - 1), capture = current or nil }
        start, current = b, cap
      end
    end
    if #line > 0 then
      runs[#runs + 1] = { text = line:sub(start), capture = current or nil }
    else
      runs[#runs + 1] = { text = "" }
    end
    out[idx] = runs
  end

  return out, ts_lang
end

return M
