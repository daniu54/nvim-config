-- Custom nvim-cmp source: suggests whole quoted strings / bracket contents
-- that already exist elsewhere in the buffer, triggered by typing the
-- opening delimiter (", ', `, (, [, {).
--
-- e.g. buffer already has `var identifier = "TEST";` somewhere — typing `"`
-- anywhere else in the buffer offers `"TEST"` as a completion. Matching is
-- substring-anywhere, not just prefix: typing `"est` still matches `"test"`.

local DELIMITERS = { '"', "'", '`', '(', '[', '{' }

-- Matches an opening delimiter followed by whatever's been typed since,
-- anchored at the cursor. Keeping the delimiter itself inside the match
-- (unlike a plain \k*) anchors cmp's replacement offset at the delimiter, so
-- confirming an item replaces the delimiter + typed text with the full token.
local KEYWORD_PATTERN = [[\%("\|'\|`\|(\|\[\|{\)\k*]]

local QUOTE_PATTERNS = {
  { delim = '"', pattern = '"[^"\n]*"' },
  { delim = "'", pattern = "'[^'\n]*'" },
  { delim = '`', pattern = '`[^`\n]*`' },
}

local BRACKET_PATTERNS = {
  { delim = '(', pattern = '%b()' },
  { delim = '[', pattern = '%b[]' },
  { delim = '{', pattern = '%b{}' },
}

local source = {}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  return DELIMITERS
end

source.get_keyword_pattern = function()
  return KEYWORD_PATTERN
end

local function collect_tokens(bufnr, delim)
  local tokens = {}
  local specs = (delim == '"' or delim == "'" or delim == '`') and QUOTE_PATTERNS or BRACKET_PATTERNS
  for _, spec in ipairs(specs) do
    if spec.delim == delim then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        for token in line:gmatch(spec.pattern) do
          if #token > 2 then
            tokens[token] = true
          end
        end
      end
    end
  end
  return tokens
end

source.complete = function(_, params, callback)
  -- Find the delimiter + typed-so-far text ending exactly at the cursor.
  local matched = vim.fn.matchstr(params.context.cursor_before_line, KEYWORD_PATTERN .. '$')
  if matched == '' then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local delim = matched:sub(1, 1)
  local typed = matched:sub(2)

  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  for token, _ in pairs(collect_tokens(bufnr, delim)) do
    -- Substring-anywhere match, not just prefix: "est" matches "test".
    if typed == '' or token:find(typed, 1, true) then
      table.insert(items, {
        label = token,
        -- Replaces the delimiter + typed text (cmp's match offset) with the
        -- full token, since KEYWORD_PATTERN anchors the offset at the delimiter.
        insertText = token,
        -- Trivially matches what's already been typed; our own substring
        -- check above already decided which tokens qualify.
        filterText = matched,
        kind = require('cmp').lsp.CompletionItemKind.Text,
      })
    end
  end

  callback({ items = items, isIncomplete = true })
end

return source
