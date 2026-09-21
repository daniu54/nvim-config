-- The GitHub URL of a file / line span / directory in the current checkout.
--
--   M.url(path, first, last) -> url, warning   (or nil, error)
--
-- Pinned to the commit HEAD is on, not to a branch: a `blob/main/...#L42` link
-- rots the moment main moves, a `blob/<sha>/...#L42` never does. That is also
-- why the lines are only trustworthy when the file matches HEAD, and why a
-- dirty file or an unpushed HEAD comes back as a *warning* next to a URL that
-- was still built -- the link is usable, the caller just has to say so.
local M = {}

local function git(dir, ...)
  local res = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  if res.code ~= 0 then return nil, vim.trim(res.stderr or "") end
  return vim.trim(res.stdout or "")
end

-- `github_personal:daniu54/repo.git` is an ssh_config alias, not a host: ask
-- ssh what it resolves to instead of hardcoding this machine's alias names.
local function resolve_host(host)
  if host:lower() == "github.com" then return "github.com" end
  local res = vim.system({ "ssh", "-G", host }, { text = true }):wait()
  if res.code ~= 0 then return host end
  return (res.stdout or ""):match("\nhostname%s+(%S+)") or (res.stdout or ""):match("^hostname%s+(%S+)") or host
end

-- Remote URL -> "owner/repo" if (and only if) it points at github.com.
local function github_slug(remote_url)
  local host, path
  host, path = remote_url:match("^[%w.+-]+://[^@/]*@?([^/:]+):?%d*/(.+)$") -- https:// ssh://
  if not host then host, path = remote_url:match("^[^@%s/:]+@([^:/%s]+):(.+)$") end -- scp-like, user@host:
  if not host then host, path = remote_url:match("^([^@%s/:]+):(.+)$") end -- scp-like, ssh alias
  if not host or resolve_host(host) ~= "github.com" then return nil end
  path = path:gsub("%.git$", ""):gsub("/+$", "")
  if not path:match("^[^/]+/[^/]+$") then return nil end
  return path
end

local function encode(path)
  return (path:gsub("[^%w%-._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- GitHub renders markdown as a page, where #L anchors go nowhere; ?plain=1
-- shows the source, which is what a line number refers to.
local RENDERED = { md = true, markdown = true, mdx = true, rst = true, adoc = true, org = true }

function M.url(path, first, last)
  if not path or path == "" then return nil, "No file" end
  path = vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
  local is_dir = vim.fn.isdirectory(path) == 1
  local dir = is_dir and path or vim.fn.fnamemodify(path, ":h")

  local sha = git(dir, "rev-parse", "--verify", "-q", "HEAD")
  if not sha then return nil, "Not a git repository (or no commits yet): " .. dir end

  -- The remote of the branch's upstream, else origin, else the only one.
  local branch = git(dir, "symbolic-ref", "--short", "-q", "HEAD")
  local remote = branch and git(dir, "config", "branch." .. branch .. ".remote")
  if not remote or remote == "" or remote == "." then
    local all = vim.split(git(dir, "remote") or "", "\n", { trimempty = true })
    remote = vim.tbl_contains(all, "origin") and "origin" or all[1]
  end
  if not remote then return nil, "No git remote" end
  local remote_url = git(dir, "remote", "get-url", remote)
  local slug = remote_url and github_slug(remote_url)
  if not slug then return nil, "Not a GitHub repository: " .. tostring(remote_url) end

  local prefix = git(dir, "rev-parse", "--show-prefix") or ""
  local rel = prefix .. (is_dir and "" or vim.fn.fnamemodify(path, ":t"))
  rel = rel:gsub("/+$", "")

  -- In HEAD, or GitHub has nothing at that address. Also covers untracked and
  -- gitignored files, and a file that only exists in the working tree.
  if rel ~= "" and not git(dir, "cat-file", "-e", sha .. ":" .. rel) then
    return nil, "Not in HEAD (untracked or not yet committed): " .. rel
  end

  local url = ("https://github.com/%s/%s/%s%s"):format(slug, is_dir and "tree" or "blob", sha, rel ~= "" and "/" .. encode(rel) or "")
  if is_dir and rel == "" then url = ("https://github.com/%s/tree/%s"):format(slug, sha) end

  if not is_dir then
    local ext = path:match("%.([^./]+)$")
    if first and RENDERED[(ext or ""):lower()] then url = url .. "?plain=1" end
    if first then
      last = last or first
      url = url .. (first == last and ("#L%d"):format(first) or ("#L%d-L%d"):format(first, last))
    end
  end

  local warnings = {}
  if git(dir, "diff", "--quiet", "HEAD", "--", path) == nil then
    -- exit 1 == differs. (git() returns nil on any non-zero exit.)
    table.insert(warnings, (is_dir and "uncommitted changes in here" or "file has uncommitted changes") .. (first and ", lines may not match" or ""))
  end
  if (git(dir, "for-each-ref", "--count=1", "--contains", sha, "--format=%(refname)", "refs/remotes") or "") == "" then
    table.insert(warnings, "HEAD is not pushed, link 404s until you push")
  end
  return url, #warnings > 0 and table.concat(warnings, "; ") or nil
end

return M
