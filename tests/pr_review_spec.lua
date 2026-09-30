local t = dofile("tests/helpers/bootstrap.lua")

local function git(cwd, ...)
	local result = vim.system({ "git", ... }, { cwd = cwd, text = true }):wait()
	if result.code ~= 0 then
		error(string.format("git %s failed: %s", table.concat({ ... }, " "), result.stderr))
	end
	return vim.trim(result.stdout)
end

local function write(root, path, lines)
	local full = vim.fs.joinpath(root, path)
	vim.fn.mkdir(vim.fs.dirname(full), "p")
	vim.fn.writefile(lines, full)
end

local function commit_all(cwd, message)
	git(cwd, "add", "-A")
	git(cwd, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
	return git(cwd, "rev-parse", "HEAD")
end

local function verify_ref_missing(cwd, ref)
	return vim.system({ "git", "rev-parse", "--verify", "--quiet", ref }, { cwd = cwd }):wait().code ~= 0
end

local function sorted(list)
	local copy = vim.deepcopy(list)
	table.sort(copy)
	return copy
end

local function with_cwd(path, fn)
	local previous = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(path))
	local ok, err = pcall(fn)
	vim.cmd("cd " .. vim.fn.fnameescape(previous))
	if not ok then
		error(err, 0)
	end
end

-- Remote with main, a clone on feature/x, and main advanced upstream after the branch point.
local function make_fixture()
	local root = vim.fn.tempname()
	local remote = vim.fs.joinpath(root, "remote.git")
	local seed = vim.fs.joinpath(root, "seed")
	local work = vim.fs.joinpath(root, "work")
	vim.fn.mkdir(root, "p")
	git(root, "init", "-q", "--bare", "-b", "main", remote)
	git(root, "clone", "-q", remote, seed)
	git(seed, "checkout", "-q", "-b", "main")
	write(seed, "a.txt", { "one", "two", "three" })
	write(seed, "gone.txt", { "bye" })
	write(seed, "base_only.txt", { "base" })
	local branch_point = commit_all(seed, "init")
	git(seed, "push", "-q", "origin", "main")

	git(root, "clone", "-q", remote, work)
	git(work, "checkout", "-q", "-b", "feature/x")
	write(work, "a.txt", { "one", "TWO", "three", "four" })
	write(work, "src/new.txt", { "fresh" })
	vim.fn.delete(vim.fs.joinpath(work, "gone.txt"))
	commit_all(work, "feature")
	write(work, "wip.txt", { "uncommitted" })
	git(work, "add", "wip.txt")

	-- Upstream moves on; its changes must not show up as part of the branch.
	write(seed, "base_only.txt", { "base", "moved on" })
	local upstream_tip = commit_all(seed, "upstream")
	git(seed, "push", "-q", "origin", "main")

	return {
		branch_point = branch_point,
		remote = remote,
		root = root,
		seed = seed,
		upstream_tip = upstream_tip,
		work = work,
	}
end

-- Branch cut from develop, which is ahead of main; the PR base is develop.
local function make_stacked_fixture()
	local fx = make_fixture()
	git(fx.seed, "checkout", "-q", "-b", "develop", fx.branch_point)
	write(fx.seed, "develop_only.txt", { "dev" })
	fx.develop_tip = commit_all(fx.seed, "develop work")
	git(fx.seed, "push", "-q", "origin", "develop")
	git(fx.work, "fetch", "-q", "origin")
	git(fx.work, "remote", "set-head", "origin", "main")
	git(fx.work, "reset", "-q", "--hard")
	git(fx.work, "checkout", "-q", "-b", "stacked", "origin/develop")
	write(fx.work, "stacked.txt", { "mine" })
	commit_all(fx.work, "stacked")
	return fx
end

-- Puts a fake `gh` first on PATH that prints `base` after `delay` seconds.
local function fake_gh(root, base, delay)
	local bin = vim.fs.joinpath(root, "bin")
	vim.fn.mkdir(bin, "p")
	local script = vim.fs.joinpath(bin, "gh")
	vim.fn.writefile({ "#!/bin/sh", "sleep " .. tostring(delay), "echo " .. base }, script)
	vim.uv.fs_chmod(script, 493)
	local previous = vim.env.PATH
	vim.env.PATH = bin .. ":" .. previous
	return function()
		vim.env.PATH = previous
	end
end

-- Required up front: the test runtimepath is relative, so require() breaks after a cd.
local doubt_module = require("doubt")
local state_module = require("doubt.state")
local pr_review_module = require("doubt.pr_review")

local function fresh_doubt(fx, review)
	local doubt = doubt_module
	doubt.setup({
		keymaps = false,
		export = { register = "a" },
		review = review,
		state_path = vim.fs.joinpath(fx.root, "state.json"),
	})
	return doubt, state_module
end

local function qf_files()
	local names = {}
	for _, item in ipairs(vim.fn.getqflist()) do
		names[vim.fn.fnamemodify(vim.fn.bufname(item.bufnr), ":t")] = true
	end
	local list = vim.tbl_keys(names)
	table.sort(list)
	return list
end

describe("pr review", function()
	local pr_review = require("doubt.pr_review")

	it("diffs against the merge base, not the base tip, and skips deleted files", function()
		local fx = make_fixture()
		git(fx.work, "fetch", "-q", "origin")
		local context, err = pr_review.resolve({ base = "main", cwd = fx.work, gh = false })
		t.assert_eq(err, nil)
		t.assert_eq(context.base_ref, "origin/main")
		t.assert_eq(context.merge_base, fx.branch_point, "merge base must be the branch point, not origin/main's tip")
		t.assert_eq(context.branch, "feature/x")
		t.assert_eq(sorted(context.files), { "a.txt", "src/new.txt", "wip.txt" })
	end)

	it("fetches the remote base so a stale local origin ref is updated", function()
		local fx = make_fixture()
		t.assert_eq(git(fx.work, "rev-parse", "origin/main"), fx.branch_point, "fixture: origin/main starts stale")
		local context = pr_review.resolve({ base = "main", cwd = fx.work, fetch = true, gh = false })
		t.assert_eq(git(fx.work, "rev-parse", "origin/main"), fx.upstream_tip, "fetch should update origin/main")
		t.assert_eq(context.merge_base, fx.branch_point)
		t.assert_eq(context.fetch_error, nil)
	end)

	it("falls back to origin/HEAD when no base is given", function()
		local fx = make_fixture()
		git(fx.work, "remote", "set-head", "origin", "main")
		local context = pr_review.resolve({ cwd = fx.work, gh = false })
		t.assert_eq(context.base_ref, "origin/main")
	end)

	it("accepts a local ref that has no origin counterpart", function()
		local fx = make_fixture()
		local context = pr_review.resolve({ base = "HEAD~1", cwd = fx.work, gh = false })
		t.assert_eq(context.base_ref, "HEAD~1")
		t.assert_eq(sorted(context.files), { "a.txt", "src/new.txt", "wip.txt" })
	end)

	it("reports an unknown base instead of guessing", function()
		local fx = make_fixture()
		local context, err = pr_review.resolve({ base = "does-not-exist", cwd = fx.work, gh = false })
		t.assert_eq(context, nil)
		t.assert_match(err, "does%-not%-exist")
	end)

	it("does not pass option-like bases to git", function()
		local fx = make_fixture()
		local sentinel = vim.fs.joinpath(fx.root, "pwned")
		local context = pr_review.resolve({ base = "--output=" .. sentinel, cwd = fx.work, gh = false })
		t.assert_eq(context, nil)
		t.assert_eq(vim.uv.fs_stat(sentinel), nil, "option-like base must not reach git as an option")
	end)

	it("rejects directories outside git", function()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local context, err = pr_review.resolve({ base = "main", cwd = dir, gh = false })
		t.assert_eq(context, nil)
		t.assert_match(err, "git")
	end)

	it("names detached HEAD sessions by commit", function()
		local fx = make_fixture()
		local head = git(fx.work, "rev-parse", "HEAD")
		git(fx.work, "checkout", "-q", "--detach")
		local context = pr_review.resolve({ base = "HEAD~1", cwd = fx.work, gh = false })
		t.assert_eq(context.branch, head:sub(1, 12))
	end)

	it("starts a branch session, lists hunks, and tells the agent which diff it reviews", function()
		local fx = make_fixture()
		git(fx.work, "fetch", "-q", "origin")
		package.loaded["doubt"] = nil
		package.loaded["doubt.state"] = nil
		local doubt = require("doubt")
		local state = require("doubt.state")

		with_cwd(fx.work, function()
			doubt.setup({
				keymaps = false,
				export = { register = "a" },
				review = { fetch = false, gh = false },
				state_path = vim.fs.joinpath(fx.root, "state.json"),
			})

			local context = doubt.start_review({ base = "main", viewer = "quickfix" })
			t.assert_eq(state.active_session_name(), "review/feature/x")
			t.assert_eq(context.viewer, "quickfix")

			local qf = vim.fn.getqflist()
			local hunks = {}
			for _, item in ipairs(qf) do
				table.insert(hunks, vim.fn.fnamemodify(vim.fn.bufname(item.bufnr), ":t") .. ":" .. item.lnum)
			end
			-- a.txt changes line 2 and adds line 4; base_only.txt and gone.txt must not appear.
			t.assert_eq(sorted(hunks), { "a.txt:2", "a.txt:4", "new.txt:1", "wip.txt:1" })

			vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(fx.work, "a.txt")))
			doubt.claim_range("concern", { bufnr = vim.api.nvim_get_current_buf(), line1 = 2, line2 = 2, note = "why caps" })
			local text = doubt.copy_export({ template = "review" })
			t.assert_match(text, "^These claims review branch `feature/x` against `origin/main` %(merge base " .. fx.branch_point:sub(1, 12))
			t.assert_match(text, "why caps")

			-- A plain session in the same editor must not inherit the review preamble.
			doubt.start_session({ name = "plain", quiet = true })
			doubt.claim_range("question", { bufnr = vim.api.nvim_get_current_buf(), line1 = 1, line2 = 1, note = "q" })
			local plain = doubt.copy_export({ template = "review" })
			t.assert_match(plain, "^The reviewer")

			-- Re-running the review resumes the same session with its claims intact.
			doubt.start_review({ base = "main", viewer = "none" })
			t.assert_eq(state.active_session_name(), "review/feature/x")
			local files = state.current_files()
			local claim_count = 0
			for _, file_state in pairs(files) do
				claim_count = claim_count + #file_state.claims
			end
			t.assert_eq(claim_count, 1)
		end)
	end)

	it("falls back to quickfix when diffview is requested but missing", function()
		local fx = make_fixture()
		git(fx.work, "fetch", "-q", "origin")
		pcall(vim.api.nvim_del_user_command, "DiffviewOpen")
		local context = pr_review.resolve({ base = "main", cwd = fx.work, gh = false })
		t.assert_eq(pr_review.open_viewer(context, "diffview"), "quickfix")
		t.assert_eq(#vim.fn.getqflist() > 0, true)
	end)

	it("uses diffview against the merge base when available", function()
		local fx = make_fixture()
		git(fx.work, "fetch", "-q", "origin")
		local received = nil
		vim.api.nvim_create_user_command("DiffviewOpen", function(opts)
			received = opts.args
		end, { nargs = "*" })
		local context = pr_review.resolve({ base = "main", cwd = fx.work, gh = false })
		t.assert_eq(pr_review.open_viewer(context, "auto"), "diffview")
		t.assert_eq(received, fx.branch_point)
		vim.api.nvim_del_user_command("DiffviewOpen")
	end)

	it("opens from local refs without waiting for gh, then retargets to the PR base", function()
		local fx = make_stacked_fixture()
		local restore = fake_gh(fx.root, "develop", 1.5)
		local ok, err = pcall(function()
			with_cwd(fx.work, function()
				local doubt = fresh_doubt(fx, { fetch = true, gh = true, viewer = "quickfix" })
				local settled = nil
				local started = vim.uv.hrtime()
				local initial = doubt.start_review({ on_settled = function(c) settled = c or false end })
				local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
				t.assert_eq(elapsed_ms < 1000, true, "start_review must not block on gh (took " .. elapsed_ms .. "ms)")
				t.assert_eq(initial.base_ref, "origin/main", "initial view uses origin/HEAD")
				t.assert_eq(qf_files(), { "develop_only.txt", "stacked.txt" }, "against main, develop's work shows up")

				t.assert_eq(vim.wait(10000, function() return settled ~= nil end, 20), true, "background refresh should finish")
				t.assert_eq(settled.base_ref, "origin/develop")
				t.assert_eq(settled.merge_base, fx.develop_tip)
				t.assert_eq(qf_files(), { "stacked.txt" }, "quickfix is rebuilt against the PR base")
				local text = pr_review_module.context_text("review/stacked")
				t.assert_match(text, "against `origin/develop`")
			end)
		end)
		restore()
		if not ok then
			error(err, 0)
		end
	end)

	it("fetches a base that is missing locally before opening", function()
		local fx = make_fixture()
		git(fx.seed, "checkout", "-q", "-b", "release", fx.branch_point)
		git(fx.seed, "push", "-q", "origin", "release")
		with_cwd(fx.work, function()
			t.assert_eq(verify_ref_missing(fx.work, "origin/release"), true, "fixture: origin/release not fetched yet")
			local doubt, state = fresh_doubt(fx, { fetch = true, gh = false, viewer = "quickfix" })
			local settled = nil
			local initial = doubt.start_review({ base = "release", on_settled = function(c) settled = c or false end })
			t.assert_eq(initial, nil, "nothing to show until the base is fetched")
			t.assert_eq(vim.wait(10000, function() return settled ~= nil end, 20), true)
			t.assert_eq(settled.base_ref, "origin/release")
			t.assert_eq(state.active_session_name(), "review/feature/x")
		end)
	end)

	it("ignores a background refresh superseded by a newer review", function()
		local fx = make_stacked_fixture()
		local restore = fake_gh(fx.root, "develop", 0.5)
		local ok, err = pcall(function()
			with_cwd(fx.work, function()
				local doubt = fresh_doubt(fx, { fetch = false, gh = true, viewer = "none" })
				local first, second = nil, nil
				doubt.start_review({ on_settled = function(c) first = c or false end })
				doubt.start_review({ on_settled = function(c) second = c or false end })
				t.assert_eq(vim.wait(10000, function() return second ~= nil end, 20), true)
				vim.wait(800, function() return first ~= nil end, 20)
				t.assert_eq(first, nil, "superseded refresh must not call back or touch the view")
				t.assert_eq(second.base_ref, "origin/develop")
			end)
		end)
		restore()
		if not ok then
			error(err, 0)
		end
	end)
end)
