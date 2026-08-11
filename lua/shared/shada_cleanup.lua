-- Reap stale ShaDa temp files.
--
-- Nvim never writes main.shada in place: it writes main.shada.tmp.a, then
-- renames it over the real file. If .tmp.a exists it tries .tmp.b, .tmp.c, ...
-- through .tmp.z, and once all 26 letters are taken it refuses to save at all:
--
--   E138: All /home/.../main.shada.tmp.X files exist, cannot write ShaDa file!
--
-- A leftover .tmp.X means an nvim was killed between "create temp" and "rename"
-- (SIGKILL, WSL shutdown, terminal window closed hard, crash). The letter is
-- never reclaimed, so the leaks accumulate silently over months until the 26th
-- one breaks all history/mark persistence.
--
-- WHY the age cutoff: a temp file belonging to a live nvim only exists for the
-- fraction of a second between create and rename, so anything older than a day
-- is certainly orphaned. This keeps the cleanup safe with several nvim
-- instances running concurrently (the normal case here — nested terminals).
--
-- WHY VimEnter + defer: this is pure housekeeping, so it must not sit in the
-- startup path. It runs once, off the critical path, with async libuv calls.

local M = {}

local MAX_AGE_SECONDS = 24 * 60 * 60

local function reap()
  local dir = vim.fn.stdpath("state") .. "/shada"
  local cutoff = os.time() - MAX_AGE_SECONDS

  vim.uv.fs_scandir(dir, function(err, handle)
    if err or not handle then
      return -- no shada dir yet (fresh install) — nothing to do
    end

    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end

      if kind == "file" and name:match("^main%.shada%.tmp%.%a$") then
        local path = dir .. "/" .. name
        vim.uv.fs_stat(path, function(stat_err, stat)
          if not stat_err and stat and stat.mtime.sec < cutoff then
            vim.uv.fs_unlink(path, function() end)
          end
        end)
      end
    end
  end)
end

function M.setup()
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      vim.defer_fn(reap, 1000)
    end,
  })
end

return M
