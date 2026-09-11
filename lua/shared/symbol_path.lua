-- symbol_path.lua — the path from the root of the tree down to the symbol
-- under the cursor, as one string: `body/div/span/div/p:hello`.
--
-- It reads treesitter's tree directly rather than an LSP document symbol list
-- or aerial's outline, and that is the point: a document symbol list is a list
-- of *symbols*, and a `<div>` twelve levels down an html file is not one — the
-- case this exists for is exactly the one an outline has nothing to say about.
-- The tree has every node, named or not, so the ancestry is always there; the
-- work is deciding which ancestors are worth a segment and what to call them.

local M = {}

local MAX_TEXT = 40

-- element-ish node types across the markup grammars (html, xml, jsx/tsx, vue,
-- svelte). Their name lives on a start_tag/self_closing_tag child.
local ELEMENT = {
  element = true,
  script_element = true,
  style_element = true,
  jsx_element = true,
  jsx_self_closing_element = true,
}

-- node types whose `name:` field is worth a segment. A `name` field alone is
-- not enough of a filter — plenty of grammars hang one on things nobody thinks
-- of as a symbol (a parameter, a field access) — so the type has to look
-- structural too.
local STRUCTURAL = {
  "function", "method", "class", "struct", "enum", "interface", "module",
  "namespace", "trait", "impl", "constructor", "type_definition", "type_alias",
  "record", "object_declaration", "package",
}

local function text_of(node, buf)
  if not node then return nil end
  local ok, s = pcall(vim.treesitter.get_node_text, node, buf)
  if not ok or not s then return nil end
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s
end

local function truncate(s)
  if #s > MAX_TEXT then return s:sub(1, MAX_TEXT - 1) .. "…" end
  return s
end

local function child_of_type(node, type_name)
  for child in node:iter_children() do
    if child:type() == type_name then return child end
  end
  return nil
end

-- the `id` attribute of an element's opening tag, if it has one. Two sibling
-- `<div>`s are indistinguishable by tag name alone, and the id is the one
-- attribute that is meant to tell them apart; classes are left out as noise.
local function element_id(tag, buf)
  for attr in tag:iter_children() do
    if attr:type() == "attribute" then
      local name = text_of(child_of_type(attr, "attribute_name"), buf)
      if name == "id" then
        local value = child_of_type(attr, "quoted_attribute_value")
          or child_of_type(attr, "attribute_value")
        if value then
          local inner = child_of_type(value, "attribute_value") or value
          local id = text_of(inner, buf)
          if id then return (id:gsub('^"', ""):gsub('"$', "")) end
        end
      end
    end
  end
  return nil
end

local function element_label(node, buf)
  local tag = child_of_type(node, "start_tag")
    or child_of_type(node, "self_closing_tag")
    or child_of_type(node, "jsx_opening_element")
    or child_of_type(node, "jsx_self_closing_element")
  if not tag then return nil end
  local name = text_of(child_of_type(tag, "tag_name"), buf)
    or text_of(child_of_type(tag, "identifier"), buf)
    or text_of(child_of_type(tag, "member_expression"), buf)
  if not name then return nil end
  local id = element_id(tag, buf)
  return id and (name .. "#" .. id) or name
end

-- the element's own text, for the last segment: `p:hello`. Only direct `text`
-- children count, so a `<div>` wrapping ten paragraphs is not labelled with the
-- first of them.
local function element_text(node, buf)
  for child in node:iter_children() do
    local t = child:type()
    if t == "text" or t == "jsx_text" or t == "raw_text" then
      local s = text_of(child, buf)
      if s then return truncate(s) end
    end
  end
  return nil
end

local function is_structural(type_name)
  for _, word in ipairs(STRUCTURAL) do
    if type_name:find(word, 1, true) then return true end
  end
  return false
end

-- one segment, or nil for a node not worth naming. Everything that is not an
-- element, a heading or a named structural node is skipped, so the path holds
-- the shape of the document and not every block and expression on the way down.
local function label(node, buf)
  local t = node:type()

  if ELEMENT[t] then return element_label(node, buf) end

  -- markdown: a section is named by its heading line
  if t == "section" then
    local heading = child_of_type(node, "atx_heading") or child_of_type(node, "setext_heading")
    local s = heading and text_of(heading, buf)
    if s then return truncate((s:gsub("^#+%s*", ""))) end
    return nil
  end

  -- css/scss: a rule is named by its selectors
  if t == "rule_set" then
    return truncate(text_of(child_of_type(node, "selectors"), buf) or "")
  end

  -- json/yaml/toml: a mapping entry is named by its key
  if t == "pair" or t == "block_mapping_pair" then
    local key = node:field("key")[1]
    local s = key and text_of(key, buf)
    if s then return (s:gsub('^"', ""):gsub('"$', "")) end
    return nil
  end

  local name = node:field("name")[1]
  if name and is_structural(t) then
    return text_of(name, buf)
  end

  return nil
end

--- The path to the node under the cursor, as `a/b/c` (`c:text` for markup).
--- Returns nil plus a reason when there is no tree or nothing to name.
function M.path(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()

  -- get_node reads the *parsed* tree and answers nil when there is none, so a
  -- buffer whose parser is attached but has not been parsed yet (no treesitter
  -- highlighting on it) would look like a buffer with no parser at all.
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil, "No treesitter parser for this buffer"
  end
  parser:parse()

  local node = vim.treesitter.get_node({ bufnr = buf, ignore_injections = false })
  if not node then
    return nil, "No treesitter node under cursor"
  end

  local segments = {}
  local leaf_text = nil
  local cur = node
  while cur do
    local seg = label(cur, buf)
    if seg then
      if #segments == 0 and ELEMENT[cur:type()] then
        leaf_text = element_text(cur, buf)
      end
      table.insert(segments, 1, seg)
    end
    cur = cur:parent()
  end

  if #segments == 0 then
    return nil, "No named symbol under cursor"
  end

  local path = table.concat(segments, "/")
  if leaf_text then path = path .. ":" .. leaf_text end
  return path
end

return M
