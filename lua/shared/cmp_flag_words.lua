-- Custom nvim-cmp source: suggests whole -flag / --flag words that already
-- exist elsewhere in the buffer, triggered by typing a leading dash.
--
-- e.g. buffer already has `--dry-run` somewhere — typing `-` (or `--`)
-- elsewhere offers `--dry-run` as a completion. Matching is substring-
-- anywhere after the dash prefix, not just prefix: typing `-erm` still
-- matches `--TERM`.
--
-- Also offers the flag together with the value that follows it in the
-- buffer (e.g. `--command value` → typing `--command` also offers
-- `--command value`, not just `--command`). If the value is quoted
-- (`--command "one two"`), the whole quoted string is captured as the
-- value; otherwise just the first word.

-- Matches 1-2 leading dashes followed by a flag-word body (letters, digits,
-- underscores, and internal dashes), anchored at the cursor. Keeping the
-- dashes inside the match (rather than a plain \k*) anchors cmp's
-- replacement offset at the first dash, so confirming an item replaces the
-- dash(es) + typed text with the full token.
local KEYWORD_PATTERN = [[-\{1,2}[A-Za-z0-9_-]*]]

-- Extracts -flag / --flag tokens from a buffer, anchored so they aren't
-- picked out of the middle of an unrelated token (e.g. `a--b`, `5-3`).
local function collect_tokens(bufnr)
  local tokens = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local pos = 1
    while true do
      local s, e = line:find('%-%-?%a[%w_%-]*', pos)
      if not s then
        break
      end
      local before = line:sub(s - 1, s - 1)
      if before == '' or not before:match('[%w_%-]') then
        local flag_token = line:sub(s, e)
        tokens[flag_token] = true

        -- Also offer "flag value" combined, where value is either a whole
        -- quoted string (if the next non-space char opens one) or just the
        -- first whitespace-delimited word.
        local remainder = line:sub(e + 1):match('^%s+(.*)$')
        if remainder then
          local qchar = remainder:sub(1, 1)
          local value
          if qchar == '"' or qchar == "'" or qchar == '`' then
            value = remainder:match('^(' .. qchar .. '[^' .. qchar .. ']*' .. qchar .. ')')
          else
            value = remainder:match('^(%S+)')
          end
          if value then
            tokens[flag_token .. ' ' .. value] = true
          end
        end
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
  return { '-' }
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

  local typed = matched:match('^%-+(.*)$') or ''
  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  for token, _ in pairs(collect_tokens(bufnr)) do
    local body = token:match('^%-+(.*)$') or token
    -- Substring-anywhere match, not just prefix: "erm" matches "TERM".
    -- Skip the token if it's exactly what's already typed at the cursor
    -- (e.g. the in-progress word itself, picked up mid-edit) — completing
    -- to identical text offers nothing.
    if token ~= matched and (typed == '' or body:find(typed, 1, true)) then
      table.insert(items, {
        label = token,
        -- Replaces the dash(es) + typed text (cmp's match offset) with the
        -- full token, since KEYWORD_PATTERN anchors the offset at the dash.
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
