-- markdown_convert.lua — :ConvertToPdf / :ConvertToTex / :ConvertToWord
--
-- Converts the current markdown buffer with `mdpdf` (see
-- /mnt/d/Programming/claude-projects/markdown-to-pdf) and writes the result
-- next to the source file.
--
-- WHY A PROGRESS WINDOW RATHER THAN vim.notify:
--   A cold build is pandoc + a headless-Chromium mermaid render + two pdflatex
--   passes; it can take a minute and it can fail halfway. mdpdf prints one
--   "==>" line per phase for exactly this reason, so the lines are streamed
--   into a scratch split as they arrive. The last two lines it prints are
--   BUILD DIR: and OUTPUT:, which are also echoed as a notification.

local M = {}

-- mdpdf_bin resolves the converter: $MDPDF_BIN wins, else the known checkout.
local function mdpdf_bin()
  return vim.env.MDPDF_BIN or "/mnt/d/Programming/claude-projects/markdown-to-pdf/mdpdf"
end

-- The scratch buffer/window the progress lines are streamed into. Kept module
-- level so a second run reuses the same window instead of stacking splits.
local state = { buf = nil, win = nil }

-- open_progress creates (or reuses) the progress split and returns its buffer.
local function open_progress(title)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].filetype = "mdpdf"
  end

  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright 12split")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.wo[state.win].number = false
    vim.wo[state.win].relativenumber = false
    vim.wo[state.win].wrap = false
    -- Hand focus straight back: the point is to watch the build, not to edit it.
    vim.api.nvim_set_current_win(prev)
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { title, "" })
  vim.bo[state.buf].modifiable = false
  return state.buf
end

-- append writes lines into the progress buffer and keeps the view at the bottom.
local function append(lines)
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local count = vim.api.nvim_buf_line_count(state.buf)
    vim.api.nvim_win_set_cursor(state.win, { count, 0 })
  end
end

-- convert runs mdpdf for one output format.
--   format: "pdf" | "tex" | "docx"
--   extra:  additional argv entries (e.g. { "--clean" }) from a command bang/args
function M.convert(format, extra)
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)

  if file == "" then
    vim.notify("mdpdf: buffer has no file on disk — save it first", vim.log.levels.ERROR)
    return
  end

  -- Convert what is on screen, not what was last saved. mdpdf reads the file
  -- from disk, so an unwritten buffer would silently export stale content.
  if vim.bo[buf].modified then
    local ok, err = pcall(vim.cmd, "silent write")
    if not ok then
      vim.notify("mdpdf: could not save buffer: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end

  local dir = vim.fn.fnamemodify(file, ":h")
  local stem = vim.fn.fnamemodify(file, ":t:r")
  local out = dir .. "/" .. stem .. "." .. format

  local args = { mdpdf_bin(), "--to", format, "--out", out }
  vim.list_extend(args, extra or {})
  table.insert(args, file)

  open_progress("mdpdf: " .. vim.fn.fnamemodify(file, ":t") .. " → " .. format)
  append({ "$ " .. table.concat(args, " "), "" })

  -- Buffer partial lines: vim.system hands over arbitrary chunks, not lines.
  local pending = ""
  local captured = { build_dir = nil, output = nil }

  local function feed(chunk)
    if not chunk or chunk == "" then
      return
    end
    pending = pending .. chunk
    local lines = vim.split(pending, "\n", { plain = true })
    -- The last element is whatever came after the final newline: hold it back.
    pending = table.remove(lines)
    if #lines > 0 then
      for _, l in ipairs(lines) do
        local d = l:match("^BUILD DIR:%s*(.+)$")
        if d then
          captured.build_dir = d
        end
        local o = l:match("^OUTPUT:%s*(.+)$")
        if o then
          captured.output = o
        end
      end
      append(lines)
    end
  end

  local on_out = vim.schedule_wrap(function(_, data)
    feed(data)
  end)

  vim.system(args, { stdout = on_out, stderr = on_out, text = true }, vim.schedule_wrap(function(result)
    if pending ~= "" then
      append({ pending })
      pending = ""
    end

    if result.code == 0 then
      local msg = {}
      if captured.output then
        table.insert(msg, "Exported: " .. captured.output)
      end
      if captured.build_dir then
        table.insert(msg, "Artifacts: " .. captured.build_dir)
      end
      append({ "", "done." })
      vim.notify(table.concat(msg, "\n"), vim.log.levels.INFO)
    else
      append({ "", "FAILED (exit " .. tostring(result.code) .. ")" })
      vim.notify(
        "mdpdf: conversion failed (exit " .. tostring(result.code) .. ") — see the mdpdf split",
        vim.log.levels.ERROR
      )
    end
  end))
end

-- Each command takes an optional bang. `:ConvertToPdf!` forces a cold build,
-- discarding the cached artifacts — the escape hatch for "the output looks
-- stale and I do not want to reason about why".
local function define(name, format)
  vim.api.nvim_create_user_command(name, function(opts)
    M.convert(format, opts.bang and { "--clean" } or nil)
  end, {
    bang = true,
    desc = "Convert the current markdown buffer to ." .. format .. " (bang = discard cached artifacts)",
  })
end

define("ConvertToPdf", "pdf")
define("ConvertToTex", "tex")
define("ConvertToWord", "docx")

-- :ConvertOpenBuildDir jumps a netrw window at the cached artifacts of the
-- current file, which is where the LaTeX log and the rendered diagrams live.
vim.api.nvim_create_user_command("ConvertOpenBuildDir", function()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("mdpdf: buffer has no file on disk", vim.log.levels.ERROR)
    return
  end
  local out = vim.fn.systemlist({ mdpdf_bin(), "--print-build-dir", file })
  if vim.v.shell_error ~= 0 or #out == 0 then
    vim.notify("mdpdf: could not resolve build dir", vim.log.levels.ERROR)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(out[#out]))
end, { desc = "Open the mdpdf build/artifact directory for the current file" })

return M
