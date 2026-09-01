-- excalidraw_render.lua — :ExcalidrawRender
--
-- Scans the current buffer for ```mermaid fenced code blocks and renders them
-- all into one locally hosted Excalidraw canvas, stacked top to bottom in the
-- order they appear in the buffer.
--
-- WHY THE CONVERSION IS NOT DONE HERE:
--   mermaid parses by laying the diagram out in a DOM, so there is no pure-Lua
--   or pure-Node path. The excalidraw-app page already bundles
--   @excalidraw/mermaid-to-excalidraw, so this command only extracts the blocks
--   and hands them to `exapp-render`, which POSTs them to the running editor;
--   the page does the conversion and writes the result back to disk.
--
--   Consequence: the first run opens a browser window and takes a moment. Later
--   runs reuse that window and swap its contents live, no reload.

local M = {}

-- Where a buffer's rendered canvas lives. Keyed by the source file so repeated
-- renders of the same document overwrite one canvas instead of littering /tmp.
local function target_for(bufname)
  local stem = vim.fn.fnamemodify(bufname, ":t:r")
  if stem == "" then
    stem = "buffer"
  end
  local key = vim.fn.sha256(bufname):sub(1, 8)
  return string.format("%s/nvim-excalidraw-%s-%s.excalidraw", vim.fn.stdpath("cache"), stem, key)
end

-- extract_blocks walks the buffer and returns every ```mermaid fence as
-- { label = "#1 · line 12", code = "..." }.
--
-- Fences are matched by their opening indentation and backtick run so that a
-- mermaid block nested inside a longer ```` fence still terminates correctly.
function M.extract_blocks(lines)
  local blocks = {}
  local i = 1

  while i <= #lines do
    local indent, ticks, info = lines[i]:match("^(%s*)(`````*)%s*(.-)%s*$")
    if not ticks then
      indent, ticks, info = lines[i]:match("^(%s*)(```+)%s*(.-)%s*$")
    end

    -- Only the language word matters: ```mermaid and ```mermaid {theme=dark}
    -- should both count.
    local lang = info and info:match("^([%w_+-]+)") or nil

    if ticks and lang and lang:lower() == "mermaid" then
      local start_line = i
      local body = {}
      i = i + 1
      while i <= #lines do
        local close_indent, close_ticks = lines[i]:match("^(%s*)(```+)%s*$")
        if close_ticks and #close_ticks >= #ticks then
          break
        end
        -- Strip the fence's own indentation so indented blocks still parse.
        table.insert(body, (lines[i]:gsub("^" .. indent, "")))
        i = i + 1
      end

      local code = vim.trim(table.concat(body, "\n"))
      if code ~= "" then
        table.insert(blocks, {
          label = string.format("#%d · line %d", #blocks + 1, start_line),
          code = code,
        })
      end
    end
    i = i + 1
  end

  return blocks
end

function M.render()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = M.extract_blocks(lines)

  if #blocks == 0 then
    vim.notify("ExcalidrawRender: no ```mermaid blocks in this buffer", vim.log.levels.WARN)
    return
  end

  local bufname = vim.api.nvim_buf_get_name(buf)
  if bufname == "" then
    bufname = "scratch-" .. buf
  end
  local out = target_for(bufname)

  vim.notify(string.format("ExcalidrawRender: rendering %d block(s)…", #blocks))

  -- The blocks go via a temp file rather than stdin: `zsh -i` would source the
  -- whole ~/.zshrc (which has interactive setup that consumes stdin), and even
  -- without -i a file is the more debuggable hand-off.
  local payload = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ vim.json.encode(blocks) }, payload)

  -- Plain `zsh -c`, not -ic: ~/.zshrc.excalidraw is self-contained.
  local cmd = {
    "zsh",
    "-c",
    string.format(
      "source ~/.zshrc.excalidraw && exapp-render %s %s",
      vim.fn.shellescape(out),
      vim.fn.shellescape(payload)
    ),
  }

  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      vim.fn.delete(payload)
      if res.code == 0 then
        vim.notify(
          string.format("ExcalidrawRender: %d block(s) → %s", #blocks, out),
          vim.log.levels.INFO
        )
      else
        local err = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
        vim.notify("ExcalidrawRender failed:\n" .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

vim.api.nvim_create_user_command("ExcalidrawRender", function()
  M.render()
end, { desc = "Render this buffer's ```mermaid blocks in the local Excalidraw editor" })

return M
