local t = dofile("tests/helpers/bootstrap.lua")

-- Required up front: the test runtimepath is relative, so require() breaks after a cd.
local doubt = require("doubt")
local state = require("doubt.state")
local herdr = require("doubt.herdr")

local function git(cwd, ...)
	local result = vim.system({ "git", ... }, { cwd = cwd, text = true }):wait()
	if result.code ~= 0 then
		error(string.format("git %s failed: %s", table.concat({ ... }, " "), result.stderr))
	end
	return vim.trim(result.stdout)
end

local function read(path)
	if not vim.uv.fs_stat(path) then
		return nil
	end
	return table.concat(vim.fn.readfile(path, "b"), "\n")
end

local function agent(fields)
	return vim.tbl_extend("force", {
		agent = "claude",
		agent_status = "idle",
		workspace_id = "w1",
	}, fields)
end

-- A git repo with one claim, and a fake herdr binary that records what it was asked to send.
local function make_env(agents, prompt_response)
	local root = vim.fn.tempname()
	local repo = vim.fs.joinpath(root, "repo")
	local fake = vim.fs.joinpath(root, "fake")
	vim.fn.mkdir(repo, "p")
	vim.fn.mkdir(fake, "p")
	git(root, "init", "-q", "-b", "main", repo)
	vim.fn.writefile({ "local x = 1", "return x" }, vim.fs.joinpath(repo, "a.lua"))
	git(repo, "add", "-A")
	git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init")

	vim.fn.writefile({ vim.json.encode({ result = { agents = agents, type = "agent_list" } }) }, vim.fs.joinpath(fake, "agents.json"))
	vim.fn.writefile({ prompt_response or '{"result":{"type":"agent_prompt"}}' }, vim.fs.joinpath(fake, "prompt_response"))
	local bin = vim.fs.joinpath(fake, "herdr")
	vim.fn.writefile({
		"#!/bin/sh",
		'dir="$(dirname "$0")"',
		'echo "$@" >> "$dir/calls"',
		'case "$1 $2" in',
		'  "agent list") cat "$dir/agents.json" ;;',
		'  "agent prompt") printf "%s" "$3" > "$dir/prompt_pane"; printf "%s" "$4" > "$dir/prompt_text"; cat "$dir/prompt_response" ;;',
		"esac",
	}, bin)
	vim.uv.fs_chmod(bin, 493)

	return { bin = bin, fake = fake, repo = repo, root = root }
end

local function with_env(env, herdr_env, fn)
	local saved = {}
	for key, value in pairs(herdr_env) do
		saved[key] = vim.env[key] or false
		vim.env[key] = value or nil
	end
	local previous_cwd = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(env.repo))
	local ok, err = pcall(function()
		doubt.setup({
			keymaps = false,
			export = { register = "a" },
			state_path = vim.fs.joinpath(env.root, "state.json"),
		})
		doubt.start_session({ name = "send-" .. vim.fn.sha256(env.root):sub(1, 8), quiet = true })
		vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(env.repo, "a.lua")))
		doubt.claim_range("concern", { bufnr = vim.api.nvim_get_current_buf(), line1 = 2, line2 = 2, note = "unique-note-7f3" })
		vim.fn.setreg("a", "sentinel")
		fn()
	end)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
	for key, value in pairs(saved) do
		vim.env[key] = value or nil
	end
	if not ok then
		error(err, 0)
	end
end

local function herdr_env(env, extra)
	return vim.tbl_extend("force", {
		HERDR_BIN_PATH = env.bin,
		HERDR_ENV = "1",
		HERDR_PANE_ID = "w1:popup",
		HERDR_WORKSPACE_ID = "w1",
	}, extra or {})
end

local function wait_for(fn, message)
	t.assert_eq(vim.wait(10000, fn, 20), true, message)
end

describe("herdr candidates", function()
	it("matches repo paths on directory boundaries only", function()
		local list = herdr.candidates({
			agent({ pane_id = "w1:a", cwd = "/src/repo" }),
			agent({ pane_id = "w1:b", cwd = "/src/repo/sub/dir" }),
			agent({ pane_id = "w1:c", cwd = "/src/repo-other" }),
			agent({ pane_id = "w1:d", cwd = "/src" }),
		}, { repo_root = "/src/repo", workspace_id = "w1" })
		t.assert_eq(vim.tbl_map(function(a) return a.pane_id end, list), { "w1:a", "w1:b" })
	end)

	it("prefers the current workspace and falls back to others", function()
		local agents = {
			agent({ pane_id = "w2:a", cwd = "/r", workspace_id = "w2" }),
			agent({ pane_id = "w1:a", cwd = "/r", workspace_id = "w1" }),
		}
		local same = herdr.candidates(agents, { repo_root = "/r", workspace_id = "w1" })
		t.assert_eq(vim.tbl_map(function(a) return a.pane_id end, same), { "w1:a" })
		local other = herdr.candidates(agents, { repo_root = "/r", workspace_id = "w9" })
		t.assert_eq(vim.tbl_map(function(a) return a.pane_id end, other), { "w1:a", "w2:a" })
	end)

	it("skips its own pane and malformed entries, and uses the foreground cwd", function()
		local list = herdr.candidates({
			agent({ pane_id = "w1:self", cwd = "/r" }),
			agent({ cwd = "/r" }),
			{ pane_id = "w1:noagent", cwd = "/r" },
			agent({ pane_id = "w1:moved", cwd = "/elsewhere", foreground_cwd = "/r/x" }),
		}, { repo_root = "/r", workspace_id = "w1", self_pane = "w1:self" })
		t.assert_eq(vim.tbl_map(function(a) return a.pane_id end, list), { "w1:moved" })
	end)
end)

describe("DoubtSend", function()
	it("submits the export to the only agent in the repo and leaves the register alone", function()
		local env = make_env({})
		local agents = {
			agent({ pane_id = "w1:p1", cwd = env.repo }),
			agent({ pane_id = "w1:p2", cwd = env.root .. "/elsewhere" }),
		}
		env = make_env(agents)
		agents[1].cwd = env.repo
		vim.fn.writefile({ vim.json.encode({ result = { agents = agents } }) }, vim.fs.joinpath(env.fake, "agents.json"))
		with_env(env, herdr_env(env), function()
			doubt.send_export()
			wait_for(function() return read(vim.fs.joinpath(env.fake, "prompt_text")) ~= nil end, "prompt should be submitted")
			t.assert_eq(read(vim.fs.joinpath(env.fake, "prompt_pane")), "w1:p1")
			t.assert_match(read(vim.fs.joinpath(env.fake, "prompt_text")), "unique%-note%-7f3")
			t.assert_eq(vim.fn.getreg("a"), "sentinel", "a successful send must not overwrite the register")
		end)
	end)

	it("refuses to type into a blocked agent", function()
		local env = make_env({})
		vim.fn.writefile({ vim.json.encode({ result = { agents = {
			agent({ pane_id = "w1:p1", cwd = env.repo, agent_status = "blocked" }),
		} } }) }, vim.fs.joinpath(env.fake, "agents.json"))
		with_env(env, herdr_env(env), function()
			doubt.send_export()
			wait_for(function() return (read(vim.fs.joinpath(env.fake, "calls")) or ""):match("agent list") ~= nil end)
			vim.wait(300)
			t.assert_eq(read(vim.fs.joinpath(env.fake, "prompt_text")), nil, "nothing may be sent to a blocked agent")
		end)
	end)

	it("does not send to a working agent when the user declines", function()
		local env = make_env({})
		vim.fn.writefile({ vim.json.encode({ result = { agents = {
			agent({ pane_id = "w1:p1", cwd = env.repo, agent_status = "working" }),
		} } }) }, vim.fs.joinpath(env.fake, "agents.json"))
		local original_confirm = vim.fn.confirm
		local asked = nil
		vim.fn.confirm = function(message)
			asked = message
			return 2
		end
		local ok, err = pcall(with_env, env, herdr_env(env), function()
			doubt.send_export()
			wait_for(function() return asked ~= nil end, "should ask before interrupting a working agent")
			vim.wait(300)
			t.assert_eq(read(vim.fs.joinpath(env.fake, "prompt_text")), nil)
		end)
		vim.fn.confirm = original_confirm
		if not ok then
			error(err, 0)
		end
	end)

	it("falls back to the register when herdr rejects the prompt", function()
		local env = make_env({}, '{"error":{"code":"agent_blocked","message":"agent is blocked"}}')
		vim.fn.writefile({ vim.json.encode({ result = { agents = {
			agent({ pane_id = "w1:p1", cwd = env.repo }),
		} } }) }, vim.fs.joinpath(env.fake, "agents.json"))
		with_env(env, herdr_env(env), function()
			doubt.send_export()
			wait_for(function() return vim.fn.getreg("a") ~= "sentinel" end, "export should land in the register")
			t.assert_match(vim.fn.getreg("a"), "unique%-note%-7f3")
		end)
	end)

	it("asks which agent when several match, then remembers the choice", function()
		local env = make_env({})
		vim.fn.writefile({ vim.json.encode({ result = { agents = {
			agent({ pane_id = "w1:p1", cwd = env.repo }),
			agent({ pane_id = "w1:p2", cwd = env.repo, agent = "codex" }),
			agent({ pane_id = "w2:p1", cwd = env.repo, workspace_id = "w2" }),
		} } }) }, vim.fs.joinpath(env.fake, "agents.json"))
		local original_select = vim.ui.select
		local offered = nil
		local selects = 0
		vim.ui.select = function(items, _, on_choice)
			selects = selects + 1
			offered = vim.tbl_map(function(a) return a.pane_id end, items)
			on_choice(items[2])
		end
		local ok, err = pcall(with_env, env, herdr_env(env), function()
			doubt.send_export()
			wait_for(function() return read(vim.fs.joinpath(env.fake, "prompt_pane")) ~= nil end)
			t.assert_eq(offered, { "w1:p1", "w1:p2" }, "only same-workspace agents are offered: " .. vim.inspect(offered))
			t.assert_eq(read(vim.fs.joinpath(env.fake, "prompt_pane")), "w1:p2")

			vim.fn.delete(vim.fs.joinpath(env.fake, "prompt_pane"))
			doubt.send_export()
			wait_for(function() return read(vim.fs.joinpath(env.fake, "prompt_pane")) ~= nil end)
			t.assert_eq(read(vim.fs.joinpath(env.fake, "prompt_pane")), "w1:p2", "second send reuses the chosen agent")
			t.assert_eq(selects, 1, "picker should not reappear")
		end)
		vim.ui.select = original_select
		if not ok then
			error(err, 0)
		end
	end)

	it("copies instead of calling herdr outside herdr", function()
		local env = make_env({})
		with_env(env, herdr_env(env, { HERDR_ENV = false }), function()
			doubt.send_export()
			wait_for(function() return vim.fn.getreg("a") ~= "sentinel" end)
			t.assert_match(vim.fn.getreg("a"), "unique%-note%-7f3")
			t.assert_eq(read(vim.fs.joinpath(env.fake, "calls")), nil, "herdr must not be invoked")
		end)
	end)

	it("copies when no agent works in this repository", function()
		local env = make_env({})
		vim.fn.writefile({ vim.json.encode({ result = { agents = {
			agent({ pane_id = "w1:p1", cwd = env.root .. "/unrelated" }),
		} } }) }, vim.fs.joinpath(env.fake, "agents.json"))
		with_env(env, herdr_env(env), function()
			doubt.send_export()
			wait_for(function() return vim.fn.getreg("a") ~= "sentinel" end)
			t.assert_eq(read(vim.fs.joinpath(env.fake, "prompt_text")), nil)
		end)
	end)
end)
