-- excalidraw_style.lua — the look sheet for :ExportToExcalidraw.
--
-- One file, `excalidraw-style.json` next to this config, merged over a small
-- built-in fallback. It is the equivalent of mdpdf's default-styles/*.tex for
-- the pdf/docx exports, minus the profiles: a canvas is one look, and a second
-- profile was churn with nothing to choose between.
--
-- The resolved table travels with the document to the Excalidraw app, which is
-- what actually draws it. Nothing here knows about elements or geometry.
-- `excalidraw-style.md` documents the keys.

local M = {}

function M.path()
  return vim.fn.stdpath("config") .. "/excalidraw-style.json"
end

-- A last-resort skeleton. It only has to keep the renderer from dividing by
-- nil if the style file is missing or unparseable — the real values live in
-- that file, where they can be read and edited.
local FALLBACK = {
  page = { contentWidth = 820, background = "#ffffff" },
  roughness = 0,
  fonts = { body = "Nunito", heading = "Nunito", code = "Cascadia" },
  title = { size = 36, color = "#1e1e1e", gapAfter = 34 },
  paragraph = { size = 20, color = "#1e1e1e", gapAfter = 22 },
}

-- merge is a deep merge of maps; anything else (numbers, strings, arrays)
-- replaces wholesale, so the style file can swap the whole `bullets` list
-- without inheriting stray entries from the fallback.
local function merge(base, over)
  if type(base) ~= "table" or type(over) ~= "table" then
    return over
  end
  if vim.islist(base) or vim.islist(over) then
    return over
  end
  local out = vim.deepcopy(base)
  for k, v in pairs(over) do
    out[k] = merge(out[k], v)
  end
  return out
end

-- load returns the resolved style table and a list of warnings.
function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    return FALLBACK, { "no style file at " .. path .. " — using built-in defaults" }
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok then
    return FALLBACK, { path .. ": " .. tostring(decoded) }
  end
  return merge(FALLBACK, decoded), {}
end

return M
