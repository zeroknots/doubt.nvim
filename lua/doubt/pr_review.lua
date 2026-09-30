-- Branch review: start a doubt session scoped to the diff between HEAD and its base branch.
local M = {}

-- Review context per session name, used to tell the agent which diff the claims refer to.
local contexts = {}

local function run_git(args, cwd, timeout)
	local command = { "git" }
	vim.list_extend(command, args)
	local ok, process = pcall(vim.system, command, { cwd = cwd, text = true })
	if not ok then
		return nil, tostring(process)
	end
	local result = process:wait(timeout)
	if result.code ~= 0 or (result.signal or 0) ~= 0 then
		local stderr = vim.trim(result.stderr or "")
		return nil, stderr ~= "" and stderr or "git command failed"
	end
	return vim.trim(result.stdout or "")
end

local function verify_commit(ref, cwd)
	if type(ref) ~= "string" or ref == "" or vim.startswith(ref, "-") then
		return nil
	end
	return run_git({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, cwd)
end

local function gh_pr_base(cwd)
	if vim.fn.executable("gh") ~= 1 then
		return nil
	end
	local ok, process = pcall(vim.system, { "gh", "pr", "view", "--json", "baseRefName", "-q", ".baseRefName" }, {
		cwd = cwd,
		text = true,
	})
	if not ok then
		return nil
	end
	local result = process:wait(10000)
	if result.code ~= 0 then
		return nil
	end
	local name = vim.trim(result.stdout or "")
	return name ~= "" and name or nil
end

-- Returns candidate refs in priority order; the first one that resolves to a commit wins.
local function base_candidates(requested, cwd, opts)
	if requested then
		if vim.startswith(requested, "origin/") or requested:find("^refs/") then
			return { requested }
		end
		return { "origin/" .. requested, requested }
	end

	local candidates = {}
	local pr_base = opts.gh ~= false and gh_pr_base(cwd) or nil
	if pr_base then
		table.insert(candidates, "origin/" .. pr_base)
	end
	local origin_head = run_git({ "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" }, cwd)
	if origin_head and origin_head ~= "" then
		table.insert(candidates, origin_head)
	end
	vim.list_extend(candidates, { "origin/main", "origin/master" })
	return candidates
end

local function fetch_remote_ref(ref, cwd)
	local branch = ref:match("^origin/(.+)$")
	if not branch then
		return true
	end
	local _, err = run_git({ "fetch", "--quiet", "origin", branch }, cwd, 30000)
	return err == nil, err
end

function M.session_name(prefix, branch)
	return (prefix or "") .. branch
end

--- Resolves the review target without touching editor state.
--- @return table|nil context, string|nil error
function M.resolve(opts)
	opts = opts or {}
	local cwd = opts.cwd or vim.fn.getcwd()

	if not run_git({ "rev-parse", "--is-inside-work-tree" }, cwd) then
		return nil, "Not inside a git repository"
	end

	local requested = opts.base
	if type(requested) == "string" then
		requested = vim.trim(requested)
		if requested == "" then
			requested = nil
		end
	end

	local base_ref = nil
	local fetch_error = nil
	for _, candidate in ipairs(base_candidates(requested, cwd, opts)) do
		local candidate_fetch_error = nil
		if opts.fetch then
			local ok, err = fetch_remote_ref(candidate, cwd)
			if not ok then
				candidate_fetch_error = err
			end
		end
		if verify_commit(candidate, cwd) then
			base_ref = candidate
			fetch_error = candidate_fetch_error
			break
		end
	end
	if not base_ref then
		return nil, string.format("Could not resolve base branch%s", requested and (": " .. requested) or "")
	end

	local head = verify_commit("HEAD", cwd)
	if not head then
		return nil, "HEAD has no commits"
	end

	local merge_base, merge_err = run_git({ "merge-base", base_ref, "HEAD" }, cwd)
	if not merge_base or merge_base == "" then
		return nil, string.format("No merge base between %s and HEAD: %s", base_ref, merge_err or "")
	end

	local branch = run_git({ "rev-parse", "--abbrev-ref", "HEAD" }, cwd)
	if not branch or branch == "" or branch == "HEAD" then
		branch = head:sub(1, 12)
	end

	-- Compare the merge base with the working tree so uncommitted fixes stay reviewable.
	local names = run_git({ "diff", "--name-only", "--no-renames", "--diff-filter=d", merge_base }, cwd) or ""
	local files = vim.split(names, "\n", { trimempty = true })

	return {
		base_ref = base_ref,
		branch = branch,
		cwd = cwd,
		fetch_error = fetch_error,
		files = files,
		head = head,
		merge_base = merge_base,
	}
end

local function diff_hunks(context)
	-- Explicit prefixes keep parsing stable under diff.mnemonicPrefix or diff.noprefix.
	local output = run_git({
		"diff",
		"-U0",
		"--no-color",
		"--no-ext-diff",
		"--no-renames",
		"--diff-filter=d",
		"--src-prefix=a/",
		"--dst-prefix=b/",
		context.merge_base,
	}, context.cwd) or ""
	local items = {}
	local path = nil
	for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
		local new_path = line:match("^%+%+%+ b/(.+)$")
		if new_path then
			path = new_path
		else
			local start, count = line:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
			if path and start then
				count = count == "" and 1 or tonumber(count)
				table.insert(items, {
					filename = vim.fs.joinpath(context.cwd, path),
					lnum = math.max(tonumber(start), 1),
					text = count == 0 and "deleted lines" or string.format("+%d lines", count),
				})
			end
		end
	end
	return items
end

local function open_quickfix(context)
	local items = diff_hunks(context)
	vim.fn.setqflist({}, " ", {
		title = string.format("doubt review: %s...%s", context.base_ref, context.branch),
		items = items,
	})
	if #items > 0 then
		vim.cmd("copen")
		vim.cmd("cfirst")
	end
end

function M.open_viewer(context, viewer)
	viewer = viewer or "auto"
	if viewer == "none" then
		return "none"
	end
	local has_diffview = vim.fn.exists(":DiffviewOpen") == 2
	if viewer == "diffview" or (viewer == "auto" and has_diffview) then
		if has_diffview then
			-- A single rev compares against the working tree, so the right side is the real, claimable file.
			vim.cmd("DiffviewOpen " .. context.merge_base)
			return "diffview"
		end
	end
	open_quickfix(context)
	return "quickfix"
end

function M.set_context(session_name, context)
	contexts[session_name] = context
end

function M.get_context(session_name)
	return session_name and contexts[session_name] or nil
end

function M.context_text(session_name)
	local context = M.get_context(session_name)
	if not context then
		return ""
	end
	return string.format(
		"These claims review branch `%s` against `%s` (merge base %s). Line numbers refer to the working tree.\n\n",
		context.branch,
		context.base_ref,
		context.merge_base:sub(1, 12)
	)
end

return M
