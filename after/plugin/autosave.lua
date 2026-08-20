-- autosave.lua — write modified buffers automatically.
--
-- SCOPE, deliberately narrow: a buffer is saved only if it is already backed by
-- a file that exists on disk. A brand-new `:enew` buffer, a `[No Name]`, a
-- terminal, a help page, a quickfix list, a plugin's scratch buffer — none of
-- them are touched. Autosave should never be the thing that decides where a
-- file lives; that is the user's `:w path` to make.
--
-- Commands:
--   :AutoSaveToggle   turn it off/on for this session
--   :AutoSaveStatus   report the current state

local M = {}

M.enabled = true

-- The events that trigger a save. InsertLeave and TextChanged cover ordinary
-- editing; FocusLost and BufLeave cover walking away mid-edit, which is the
-- case that actually loses work.
local trigger_events = { "InsertLeave", "TextChanged", "FocusLost", "BufLeave" }

-- should_save decides whether one buffer is eligible.
local function should_save(buf)
  if not M.enabled then
    return false
  end
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
    return false
  end
  -- buftype is "" only for a normal file buffer: terminals, help, quickfix,
  -- prompt and acwrite buffers all set it to something.
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    return false
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return false
  end
  -- The file must already exist. This is the rule that keeps autosave from
  -- creating files the user never asked to create.
  if vim.fn.filereadable(name) ~= 1 then
    return false
  end
  -- A file that vanished or turned read-only under us is left alone; writing
  -- would either recreate it or raise a prompt in the middle of typing.
  if vim.fn.filewritable(name) ~= 1 then
    return false
  end
  return true
end

-- save writes one buffer without disturbing the editing session: `silent`
-- suppresses the "N lines written" message, `noautocmd` is NOT used because
-- LSP willSave handlers should still run, exactly as on a manual :w.
-- Formatting is the exception — see autosave_in_progress below.
local function save(buf)
  if not should_save(buf) then
    return
  end
  -- Autosave must not reformat the file — the user formats on their own
  -- terms. conform.lua's format_on_save checks this flag and skips.
  vim.b[buf].autosave_in_progress = true
  vim.api.nvim_buf_call(buf, function()
    -- pcall: a BufWritePre autocmd that errors (a formatter that cannot parse
    -- half-typed code, say) must not turn into an error popup on every
    -- keystroke. The buffer simply stays modified and the next trigger retries.
    pcall(function()
      vim.cmd("silent lockmarks write")
    end)
  end)
  vim.b[buf].autosave_in_progress = false
end

local group = vim.api.nvim_create_augroup("AutoSave", { clear = true })

vim.api.nvim_create_autocmd(trigger_events, {
  group = group,
  callback = function(args)
    -- Defer by a tick: TextChanged fires inside the change, and writing from
    -- there can fight with pending undo state.
    vim.schedule(function()
      save(args.buf)
    end)
  end,
  desc = "Autosave modified buffers whose file already exists on disk",
})

vim.api.nvim_create_user_command("AutoSaveToggle", function()
  M.enabled = not M.enabled
  vim.notify("autosave " .. (M.enabled and "enabled" or "disabled"), vim.log.levels.INFO)
end, { desc = "Toggle automatic saving of file-backed buffers" })

vim.api.nvim_create_user_command("AutoSaveStatus", function()
  vim.notify("autosave is " .. (M.enabled and "enabled" or "disabled"), vim.log.levels.INFO)
end, { desc = "Report whether autosave is on" })

return M
