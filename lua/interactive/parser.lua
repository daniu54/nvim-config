local M = {}

-- Custom commands can be registered here as name -> function(instr) -> cmd_string.
-- Empty for now: everything falls through to the shell.
M.custom_commands = {}

-- Number of "''" occurrences in a line - callers track the running parity
-- across lines to tell whether a "''" opened earlier is still unclosed.
function M.marker_count(line)
  local _, count = line:gsub("''", "''")
  return count
end

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

-- Multi-line strings are written inline with "''" as the continuation
-- marker, e.g.:
--   /echo "line one''
--   line two
--   line three"''
-- A "''" left unmatched at the end of a line means the instruction isn't
-- finished - keep reading lines (joined with real newlines) until the count
-- of "''" seen since the start is even again. All "''" occurrences are then
-- stripped, leaving the real quotes/newlines the shell sees. Note this means
-- a literal shell '' (empty-string idiom) on its own line will be
-- misread as opening a span - use $'' or "" instead if that's meant literally.
--
-- `lines` is the buffer text from the instruction's start row through its
-- end row inclusive, with `lines[1]` already stripped of the leading "/".
function M.parse_multiline(lines)
  local raw = table.concat(lines, "\n")

  local n = raw:match("%-%-lines%s+(%d+)")
  if n then
    raw = raw:gsub("%-%-lines%s+%d+%s*", "", 1)
  end

  raw = raw:gsub("''", "")
  raw = raw:gsub("%s+$", "")
  if raw == "" then
    return nil
  end

  return { raw = raw, name = raw:match("^(%S+)"), lines = n and tonumber(n) or nil }
end

return M
