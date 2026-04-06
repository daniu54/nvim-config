-- nvsearch.lua — telescope-based search commands for nvfind/nvgrep/nvdfind/nvdgrep
-- Invoked from shell via: nvim -c 'lua require("shared.nvsearch").find()'
-- Query passed via NVSEARCH_QUERY env var to avoid shell quoting issues.

local M = {}

local function get_query()
	return os.getenv("NVSEARCH_QUERY") or ""
end

-- Detect the base branch (main or master) by checking origin/HEAD, then fallbacks.
local function get_base_branch()
	local ref = vim.fn.system("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null"):gsub("%s+$", "")
	local branch = ref:match(".+/(.+)$")
	if branch and branch ~= "" then return branch end

	-- fallback: check if main or master exist locally
	if vim.fn.system("git rev-parse --verify main 2>/dev/null"):match("%x%x%x%x") then
		return "main"
	end
	return "master"
end

-- Returns list of files changed vs the base branch, or (nil, error_message).
local function get_diff_files()
	-- Ensure we're in a git repo
	vim.fn.system("git rev-parse --git-dir 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return nil, "Not inside a git repository"
	end

	local base = get_base_branch()
	local merge_base = vim.fn.system("git merge-base HEAD " .. base .. " 2>/dev/null"):gsub("%s+", "")
	if merge_base == "" then
		return nil, "Cannot find merge base with '" .. base .. "'"
	end

	-- Check if we're already on the base branch (no diff)
	local current = vim.fn.system("git rev-parse --abbrev-ref HEAD 2>/dev/null"):gsub("%s+", "")
	if current == base then
		return nil, "Already on base branch '" .. base .. "' — no diff"
	end

	local files = vim.fn.systemlist("git diff --name-only " .. merge_base .. " 2>/dev/null")
	-- Filter to only readable files (excludes deleted files)
	files = vim.tbl_filter(function(f) return vim.fn.filereadable(f) == 1 end, files)

	if #files == 0 then
		return nil, "No changed files vs '" .. base .. "'"
	end
	return files, nil
end

-- nvfind: telescope file picker from CWD, optionally pre-filtered
function M.find()
	vim.schedule(function()
		require("telescope.builtin").find_files({
			default_text = get_query(),
			hidden = false,
		})
	end)
end

-- nvgrep: smart-case grep from CWD
function M.grep()
	vim.schedule(function()
		require("telescope.builtin").grep_string({
			search = get_query(),
			use_regex = true,
			additional_args = { "--smart-case" },
			prompt_title = "Grep: " .. get_query(),
		})
	end)
end

-- nvdfind: telescope file picker scoped to git diff files
function M.dfind()
	vim.schedule(function()
		local pickers = require("telescope.pickers")
		local finders = require("telescope.finders")
		local conf = require("telescope.config").values

		local files, err = get_diff_files()
		if not files then
			vim.notify("[nvdfind] " .. err, vim.log.levels.WARN)
			return
		end

		pickers.new({}, {
			prompt_title = "Diff Files (" .. #files .. " changed) — " .. get_base_branch(),
			default_text = get_query(),
			finder = finders.new_table({ results = files }),
			sorter = conf.generic_sorter({}),
			previewer = conf.file_previewer({}),
		}):find()
	end)
end

-- nvdgrep: smart-case grep scoped to git diff files
function M.dgrep()
	vim.schedule(function()
		local files, err = get_diff_files()
		if not files then
			vim.notify("[nvdgrep] " .. err, vim.log.levels.WARN)
			return
		end

		require("telescope.builtin").grep_string({
			search = get_query(),
			use_regex = true,
			additional_args = { "--smart-case" },
			search_dirs = files,
			prompt_title = "Grep in Diff (" .. #files .. " files): " .. get_query(),
		})
	end)
end

return M
