-- Custom nvim-cmp source: suggests whole quoted strings / bracket contents
-- that already exist elsewhere in the buffer, triggered by typing the
-- opening delimiter (", ', `, (, [, {).
--
-- e.g. buffer already has `var identifier = "TEST";` somewhere — typing `"`
-- anywhere else in the buffer offers `"TEST"` as a completion.

local DELIMITERS = { '"', "'", '`', '(', '[', '{' }

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

-- Plain word chars only: the opening delimiter itself is left untouched in
-- the buffer, we only ever insert/filter on what comes after it.
source.get_keyword_pattern = function()
  return [[\k*]]
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
  local before_char = string.match(params.context.cursor_before_line, '(.)%s*$')
  if not before_char or not vim.tbl_contains(DELIMITERS, before_char) then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  for token, _ in pairs(collect_tokens(bufnr, before_char)) do
    -- The opening delimiter is already in the buffer, so only insert the rest.
    local rest = token:sub(2)
    table.insert(items, {
      label = token,
      insertText = rest,
      filterText = rest,
      kind = require('cmp').lsp.CompletionItemKind.Text,
    })
  end

  callback({ items = items, isIncomplete = false })
end

return source
