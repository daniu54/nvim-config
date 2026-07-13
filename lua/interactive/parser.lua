local M = {}

-- Custom commands can be registered here as name -> function(instr) -> cmd_string.
-- Empty for now: everything falls through to the shell.
M.custom_commands = {}

-- A line is an instruction if it starts with "/" and isn't already marked done.
-- The rest of the line (after the slash) is passed to the shell as-is, so
-- quoting/argument-splitting is the shell's job, not ours - except for
-- "--lines <n>", which is intercepted here (to size that instruction's
-- output region) and stripped before the command ever reaches the shell.
function M.parse(line)
  if line:match("^##%s") then
    return nil
  end
  local rest = line:match("^/(.+)$")
  if not rest or rest == "" then
    return nil
  end

  local lines = rest:match("%-%-lines%s+(%d+)")
  if lines then
    rest = rest:gsub("%-%-lines%s+%d+%s*", "", 1)
    rest = rest:gsub("%s+$", "")
  end
  if rest == "" then
    return nil
  end

  return { raw = rest, name = rest:match("^(%S+)"), lines = lines and tonumber(lines) or nil }
end

return M
