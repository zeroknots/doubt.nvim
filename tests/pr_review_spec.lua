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
end)
