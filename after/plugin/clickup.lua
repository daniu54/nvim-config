-- clickup.lua — :ClickupTodosRun: execute clickuptodos "/instruction" lines
-- in the current buffer in place, via `clickup todos run -` (stdin/stdout),
-- with no temp file involved.

local function clickup_bin()
  return vim.env.CLICKUP_BIN or "/mnt/d/Programming/clickup-terminal/clickup-terminal/clickup"
end

local function clickup_todos_run()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.bo[buf].modifiable then
    vim.notify("ClickupTodosRun: buffer is not modifiable", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local input = table.concat(lines, "\n")

  vim.notify("ClickupTodosRun: running instructions...", vim.log.levels.INFO)

  vim.system(
    { clickup_bin(), "todos", "run", "-" },
    { stdin = input, text = true },
    vim.schedule_wrap(function(result)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end

      if result.stdout and result.stdout ~= "" then
        local out_lines = vim.split(result.stdout, "\n", { plain = true })
        -- clickup todos run never emits a trailing blank line intentionally;
        -- strip one if present so :wq-style output doesn't grow a stray
        -- empty last line on every run.
        if out_lines[#out_lines] == "" then
          table.remove(out_lines)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, out_lines)
      end

      if result.code == 0 then
        vim.notify("ClickupTodosRun: all instructions completed", vim.log.levels.INFO)
      else
        local err = (result.stderr or ""):gsub("%s+$", "")
        vim.notify(
          "ClickupTodosRun: some instructions failed — fix and re-run\n" .. err,
          vim.log.levels.WARN
        )
      end
    end)
  )
end

vim.api.nvim_create_user_command("ClickupTodosRun", clickup_todos_run, {
  desc = "Run clickuptodos /instructions in the current buffer, in place (no temp file)",
})
