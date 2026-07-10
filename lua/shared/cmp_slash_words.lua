-- Custom nvim-cmp source: suggests whole /command words that already exist
-- elsewhere in the buffer, triggered by typing `/`.
--
-- e.g. buffer already has `/worktree-start` somewhere — typing `/wor`
-- elsewhere offers `/worktree-start` as a completion. Matching is
-- substring-anywhere after the slash, not just prefix.
--
-- Deliberately excluded: `//` comments. A slash command must be preceded by
-- whitespace or line-start (never another `/`), and must be followed
-- immediately by a letter (never another `/`) — so neither the first nor
-- the second slash of a `//` comment can ever start a match.

-- \zs drops the leading whitespace/line-start from the match itself, so the
-- match (and cmp's replacement offset) starts exactly at the `/`.
local KEYWORD_PATTERN = [[\%(^\|\s\)\zs/\a[A-Za-z0-9_-]*]]

-- Extracts /command tokens from a buffer. Same boundary rule as above:
-- must follow whitespace/line-start, so `//` comments and inline division
-- (`a/b`) are never picked up.
local function collect_tokens(bufnr)
  local tokens = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local pos = 1
    while true do
      local s, e = line:find('/%a[%w_%-]*', pos)
      if not s then
        break
      end
      local before = line:sub(s - 1, s - 1)
      if before == '' or before:match('%s') then
        tokens[line:sub(s, e)] = true
      end
      pos = e + 1
    end
  end
  return tokens
end

local source = {}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  return { '/' }
end

source.get_keyword_pattern = function()
  return KEYWORD_PATTERN
end

source.complete = function(_, params, callback)
  local matched = vim.fn.matchstr(params.context.cursor_before_line, KEYWORD_PATTERN .. '$')
  if matched == '' then
    callback({ items = {}, isIncomplete = false })
    return
  end

  local typed = matched:sub(2)
  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  for token, _ in pairs(collect_tokens(bufnr)) do
    -- Substring-anywhere match, not just prefix: "flect" matches "/reflect".
    -- Skip the token if it's exactly what's already typed at the cursor
    -- (the in-progress word itself) — completing to identical text offers
    -- nothing.
    if token ~= matched and token:find(typed, 1, true) then
      table.insert(items, {
        label = token,
        -- Replaces the slash + typed text (cmp's match offset) with the
        -- full token, since KEYWORD_PATTERN anchors the offset at the slash.
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
