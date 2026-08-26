-- autosave.lua — write modified buffers automatically.
--
-- SCOPE, deliberately narrow: a buffer is saved only if it is already backed by
-- a file that exists on disk. A brand-new `:enew` buffer, a `[No Name]`, a
-- terminal, a help page, a quickfix list, a plugin's scratch buffer — none of
-- them are touched. Autosave should never be the thing that decides where a
-- file lives; that is the user's `:w path` to make.
--
-- Autosave also never resolves a conflict. If the file on disk is not the file
-- this buffer was last in sync with, the write is refused and the user is told
-- to pick: `:w!` to overwrite disk, `:e!` to throw the buffer away and reload.
-- See "CONFLICT GATE" below.
--
-- Commands:
--   :AutoSaveToggle   turn it off/on for this session
--   :AutoSaveStatus   report the current state

local M = {}

M.enabled = true

local uv = vim.uv or vim.loop

-- The events that trigger a save. InsertLeave and TextChanged cover ordinary
-- editing; FocusLost and BufLeave cover walking away mid-edit, which is the
-- case that actually loses work.
local trigger_events = { "InsertLeave", "TextChanged", "FocusLost", "BufLeave" }

-- ---------------------------------------------------------------------------
-- CONFLICT GATE
--
-- Without this, an autosave into a file that changed underneath the buffer does
-- NOT quietly clobber it — it raises vim's own blocking dialog,
--
--     WARNING: The file has been changed since reading it!!!
--     Do you really want to write to it (y/n)?
--
-- in the middle of typing, and `silent` does not suppress it (verified). That
-- prompt is right for a deliberate `:w` and wrong for a keystroke-driven one,
-- so autosave answers "no" on the user's behalf by never reaching the write.
--
-- Two independent detectors, because neither alone is sufficient:
--
--   1. A latch on FileChangedShell. This is vim's own detection, the one that
--      raises the FILE CHANGED ON DISK bar (lua/shared/file_changed_bar.lua),
--      and it is why the bar and this gate can never disagree. It has to be
--      *latched*: vim re-stamps the buffer's mtime as it fires, so the event
--      is delivered exactly once per external change (verified) — polling it
--      a second time reports all-clear on a conflict that is still unresolved.
--
--   2. A stamp of our own — the disk mtime (to the nanosecond) and size that
--      the buffer was last known to match. This one does not care when the
--      last :checktime ran, so it still catches a change that arrived in a
--      window where nothing triggered vim's check.
--
-- Both are cleared the moment the buffer and disk are back in sync, which is
-- exactly BufReadPost (`:e!`) and BufWritePost (`:w!`, or an autosave that got
-- through) — so resolving the conflict either way un-pauses autosave with no
-- further ceremony.
-- ---------------------------------------------------------------------------

-- disk_stamp identifies *which version* of a file is currently on disk.
-- Nanosecond mtime rather than |getftime()|'s whole seconds: an external write
-- landing in the same second as ours is precisely the race worth catching.
local function disk_stamp(name)
  local st = uv.fs_stat(name)
  if not st then
    return nil
  end
  return string.format("%d.%09d:%d", st.mtime.sec, st.mtime.nsec, st.size)
end

-- sync_state records "this buffer now matches what is on disk" and drops any
-- standing conflict.
local function sync_state(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return
  end
  vim.b[buf].autosave_disk_stamp = disk_stamp(name)
  vim.b[buf].autosave_conflict = false
  vim.b[buf].autosave_paused_for = nil
end

-- Every buffer that reaches a file-in-sync state gets stamped: on read (:e,
-- :e!, a reload) and on any successful write, ours or the user's.
local group = vim.api.nvim_create_augroup("AutoSave", { clear = true })

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = group,
  callback = function(args)
    sync_state(args.buf)
  end,
  desc = "Autosave: remember the on-disk version this buffer matches",
})

-- The latch. file_changed_bar.lua owns `v:fcs_choice` (it sets "" so vim
-- neither reloads nor prints its own W11/W12); this handler only records that
-- the buffer is now out of sync. Guarded on `modified`, because an unmodified
-- buffer whose file changed is a reload, not a conflict — there is nothing of
-- the user's to lose, and BufReadPost will re-stamp it.
vim.api.nvim_create_autocmd("FileChangedShell", {
  group = group,
  callback = function(args)
    if vim.api.nvim_buf_is_valid(args.buf) and vim.bo[args.buf].modified then
      vim.b[args.buf].autosave_conflict = true
    end
  end,
  desc = "Autosave: latch that this buffer conflicts with the file on disk",
})

-- other_buffers_for finds any OTHER loaded buffer editing the same file.
--
-- In practice this is close to unreachable, and that is worth writing down
-- rather than rediscovering: vim identifies buffers by (device, inode), not by
-- path, so the same file opened in ten tabs — by absolute path, by relative
-- path, through a symlink, through a hard link — is one single buffer every
-- time (verified). Multiple tabs on one file therefore share one set of
-- contents and cannot diverge, so autosaving one cannot clobber another.
--
-- The gap it does close: two buffers can end up on one path when the file the
-- first was opened from is *replaced* (a `git checkout` swapping the inode)
-- and the path is then opened again. Both then write the same path, and the
-- one autosave picks wins silently. Cheap to check, so it is checked.
--
-- It is also the one check here that costs a stat per open buffer, on an event
-- that fires per keystroke-ish, so the answer is cached and only recomputed
-- when the buffer list itself changes (buflist_gen below).
local function other_buffers_for(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local st = uv.fs_stat(name)
  local others = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local other = vim.api.nvim_buf_get_name(b)
      if other ~= "" then
        local same = other == name
        if not same and st then
          local ost = uv.fs_stat(other)
          same = ost ~= nil and ost.ino == st.ino and ost.dev == st.dev
        end
        if same then
          others[#others + 1] = b
        end
      end
    end
  end
  return others
end

-- buflist_gen ticks whenever the set of buffers, or a buffer's file, changes —
-- the only things that can change the answer above. Between ticks the cached
-- count stands, so the common case (nothing opened or closed since the last
-- keystroke) costs one table lookup instead of a stat per buffer.
--
-- A file swapped underneath an existing buffer raises no buffer event and so
-- does not tick this, but it does change the file's mtime — and the stamp
-- check above runs first and refuses the write on its own.
local buflist_gen = 0
local alias_cache = {}

vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufFilePost", "BufNew" }, {
  group = group,
  callback = function()
    buflist_gen = buflist_gen + 1
    alias_cache = {}
  end,
  desc = "Autosave: invalidate the same-file-open-twice cache",
})

local function aliased_buffer_count(buf)
  local hit = alias_cache[buf]
  if hit and hit.gen == buflist_gen then
    return hit.count
  end
  local count = #other_buffers_for(buf)
  alias_cache[buf] = { gen = buflist_gen, count = count }
  return count
end

-- blocked_reason returns nil when it is safe to write, or a human-readable
-- reason not to.
local function blocked_reason(buf)
  -- Let vim run its own mtime check first, so a conflict raises the FILE
  -- CHANGED ON DISK bar exactly as it would on any other event — the gate and
  -- the visible warning stay one and the same thing. It only fires the
  -- autocmd; `v:fcs_choice = ""` means nothing is reloaded behind our back.
  pcall(vim.cmd, "silent! checktime " .. buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  if vim.b[buf].autosave_conflict then
    return "it changed on disk"
  end

  local known = vim.b[buf].autosave_disk_stamp
  local now = disk_stamp(vim.api.nvim_buf_get_name(buf))
  -- An unknown stamp is not evidence of a conflict, so it does not block; the
  -- next sync_state fills it in.
  if known and now and known ~= now then
    return "it changed on disk"
  end

  local n = aliased_buffer_count(buf)
  if n > 0 then
    return string.format("it is open in %d other buffer%s", n, n == 1 and "" or "s")
  end

  return nil
end

-- warn_once keeps the gate from repeating itself on every keystroke: the same
-- reason for the same buffer is announced once, and only speaks again after
-- the buffer goes back in sync (sync_state clears the marker).
local function warn_once(buf, reason)
  if vim.b[buf].autosave_paused_for == reason then
    return
  end
  vim.b[buf].autosave_paused_for = reason
  vim.notify(
    string.format(
      "autosave paused for %s: %s.\n:w! to overwrite the file, :e! to discard this buffer and reload",
      vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:."),
      reason
    ),
    vim.log.levels.WARN
  )
end

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

  local reason = blocked_reason(buf)
  if reason then
    warn_once(buf, reason)
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
  local msg = "autosave is " .. (M.enabled and "enabled" or "disabled")
  local paused = vim.b.autosave_paused_for
  if paused then
    msg = msg .. ", but paused for this buffer: " .. paused .. " (:w! to overwrite, :e! to reload)"
  end
  vim.notify(msg, vim.log.levels.INFO)
end, { desc = "Report whether autosave is on" })

return M
