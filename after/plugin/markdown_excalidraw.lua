-- markdown_excalidraw.lua — :ExportToExcalidraw
--
-- Exports the current markdown buffer to an Excalidraw canvas: the whole
-- document, not just its diagrams — headings, prose, lists, quotes, tables,
-- code (syntax-highlighted) and images, with every ```mermaid block rendered
-- in place, laid out in one column as if it had been typed into the canvas.
--
-- The sibling of :ConvertToPdf / :ConvertToWord (markdown_convert.lua), and it
-- reads the same dialect, so a document written for mdpdf exports here without
-- edits. /newpage is the one directive with no meaning on a canvas: a canvas
-- has no pages, so it is parsed and dropped.
--
-- SPLIT OF WORK — why this file is only half the feature:
--   Laying the document out needs a browser. Wrapping a line means measuring a
--   string in a font, a mermaid diagram lays out in a DOM, an image has to be
--   decoded to learn its size. All of that happens in the excalidraw-app page
--   (app/src/document.js in ~/excalidraw-src), which is where :ExcalidrawRender
--   already sends mermaid blocks for the same reason.
--
--   So this file does everything that can be decided by reading text:
--   parsing the markdown into blocks (lua/shared/md_document.lua), tokenising
--   code with treesitter, reading images off disk into data URLs, and resolving
--   the style sheet (lua/shared/excalidraw_style.lua). It hands the result to
--   `exapp-render-doc`, which POSTs it to the running editor.

local doc = require("shared.md_document")
local style_loader = require("shared.excalidraw_style")

local M = {}

local MIME = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  svg = "image/svg+xml",
  bmp = "image/bmp",
  avif = "image/avif",
  ico = "image/x-icon",
}

-- Excalidraw stores an embedded image inline in the scene file, so a big one is
-- paid for on every save. Anything past this is left as a placeholder with the
-- path on it rather than quietly bloating the canvas.
local MAX_IMAGE_BYTES = 8 * 1024 * 1024

-- resolve_image finds the file a markdown image points at. Relative paths are
-- relative to the document, as they are for every other markdown tool; a
-- Windows path is accepted because half the notes in this setup live on D:.
local function resolve_image(src, base_dir)
  if src:match("^https?://") or src:match("^data:") then
    return nil, "remote images are not embedded"
  end

  local path = src:gsub("^<", ""):gsub(">$", "")
  path = path:gsub("%%20", " ")

  if path:match("^%a:[/\\]") or path:match("\\") then
    local converted = vim.fn.system({ "wslpath", "-u", path })
    if vim.v.shell_error == 0 then
      path = vim.trim(converted)
    end
  end

  path = vim.fn.expand(path)
  if not path:match("^/") then
    path = base_dir .. "/" .. path
  end
  path = vim.fs.normalize(path)

  if vim.fn.filereadable(path) == 0 then
    return nil, "not readable: " .. path
  end
  return path
end

local function read_data_url(path)
  local size = vim.fn.getfsize(path)
  if size > MAX_IMAGE_BYTES then
    return nil, string.format("too large to embed (%.1f MB)", size / 1024 / 1024)
  end
  local fh = io.open(path, "rb")
  if not fh then
    return nil, "could not open " .. path
  end
  local data = fh:read("*a")
  fh:close()
  local ext = vim.fn.fnamemodify(path, ":e"):lower()
  local mime = MIME[ext] or "image/png"
  return "data:" .. mime .. ";base64," .. vim.base64.encode(data), nil, mime
end

-- build assembles the payload the app renders: the block list with everything
-- that needed the filesystem or treesitter already resolved, plus the style.
function M.build(lines, base_dir)
  local blocks, meta = doc.parse(lines)
  local style, warnings = style_loader.load()
  local notes = vim.deepcopy(warnings)

  for _, block in ipairs(blocks) do
    if block.type == "code" then
      local runs, lang = doc.highlight_code(block.lines, block.lang)
      block.runs = runs
      block.resolved_lang = lang
      block.lines = nil -- the runs carry the text; sending both doubles the payload
    elseif block.type == "toc" then
      block.entries = meta.headings
    elseif block.type == "image" then
      local path, err = resolve_image(block.src, base_dir)
      if path then
        local url, read_err, mime = read_data_url(path)
        if url then
          block.dataURL = url
          block.mimeType = mime
        else
          block.error = read_err
          table.insert(notes, block.src .. ": " .. read_err)
        end
      else
        block.error = err
        table.insert(notes, block.src .. ": " .. err)
      end
    end
  end

  return { blocks = blocks, style = style, title = meta.title }, notes
end

-- Where a buffer's canvas lands. Beside the document, like the pdf/docx
-- exports — a re-export overwrites it, same as re-running :ConvertToPdf.
-- With a bang it goes to the cache instead, for a look at a document you do
-- not want to leave an .excalidraw file next to.
local function target_for(file, scratch)
  if scratch or file == "" then
    local stem = file ~= "" and vim.fn.fnamemodify(file, ":t:r") or "buffer"
    local key = vim.fn.sha256(file ~= "" and file or tostring(vim.uv.hrtime())):sub(1, 8)
    return string.format("%s/nvim-excalidraw-doc-%s-%s.excalidraw", vim.fn.stdpath("cache"), stem, key)
  end
  return vim.fn.fnamemodify(file, ":r") .. ".excalidraw"
end

function M.export(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- The buffer, not the file on disk: unlike mdpdf, nothing here re-reads the
  -- document, so there is no reason to force a write first.
  local base_dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or vim.fn.getcwd()

  local ok, payload, notes = pcall(M.build, lines, base_dir)
  if not ok then
    vim.notify("ExportToExcalidraw: " .. tostring(payload), vim.log.levels.ERROR)
    return
  end
  if #payload.blocks == 0 then
    vim.notify("ExportToExcalidraw: nothing to export — the document is empty", vim.log.levels.WARN)
    return
  end

  local out = target_for(file, opts.scratch)
  local tmp = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ vim.json.encode(payload) }, tmp)

  local counts = {}
  for _, block in ipairs(payload.blocks) do
    counts[block.type] = (counts[block.type] or 0) + 1
  end
  local summary = {}
  for _, kind in ipairs({ "heading", "paragraph", "list", "code", "mermaid", "table", "image" }) do
    if counts[kind] then
      table.insert(summary, string.format("%d %s", counts[kind], kind))
    end
  end

  vim.notify(
    string.format("ExportToExcalidraw: rendering %s…", table.concat(summary, ", ")),
    vim.log.levels.INFO
  )
  for _, note in ipairs(notes or {}) do
    vim.notify("ExportToExcalidraw: " .. note, vim.log.levels.WARN)
  end

  -- Plain `zsh -c`, not -ic: ~/.zshrc.excalidraw is self-contained, and an
  -- interactive zsh would source the whole rc (whose setup eats stdin).
  local cmd = {
    "zsh",
    "-c",
    string.format(
      "source ~/.zshrc.excalidraw && exapp-render-doc %s %s",
      vim.fn.shellescape(out),
      vim.fn.shellescape(tmp)
    ),
  }

  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      vim.fn.delete(tmp)
      if res.code == 0 then
        vim.notify("ExportToExcalidraw: " .. out, vim.log.levels.INFO)
      else
        local err = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
        vim.notify("ExportToExcalidraw failed:\n" .. err, vim.log.levels.ERROR)
      end
    end)
  end)
end

-- One command, one look: `excalidraw-style.json` is the only style sheet, so
-- there is nothing to select and the bang is the whole signature.
--
--   :ExportToExcalidraw    -> <stem>.excalidraw beside the document
--   :ExportToExcalidraw!   -> a scratch canvas in the cache dir instead
vim.api.nvim_create_user_command("ExportToExcalidraw", function(cmd)
  M.export({ scratch = cmd.bang })
end, {
  bang = true,
  desc = "Export the current markdown buffer to an Excalidraw canvas (bang = scratch file)",
})

return M
