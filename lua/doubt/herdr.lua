-- Herdr integration: find the agent pane working in this repository and submit exports to it.
local M = {}

-- Pane chosen per session name, so repeated sends skip the picker.
local remembered = {}

local function herdr_bin()
	local bin = vim.env.HERDR_BIN_PATH
	if type(bin) == "string" and bin ~= "" then
		return bin
	end
	return "herdr"
end

function M.available()
	return vim.env.HERDR_ENV == "1" and vim.fn.executable(herdr_bin()) == 1
end

local function decode(stdout)
	local ok, decoded = pcall(vim.json.decode, stdout or "")
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

-- herdr prints a JSON envelope on stdout for both success and failure.
local function run(args, callback)
	local command = { herdr_bin() }
	vim.list_extend(command, args)
	local ok, err = pcall(vim.system, command, { text = true, timeout = 15000 }, vim.schedule_wrap(function(result)
		local decoded = decode(result.stdout)
		if decoded and type(decoded.error) == "table" then
			callback(nil, decoded.error.message or "herdr request failed", decoded.error.code)
			return
		end
		if result.code ~= 0 or not decoded then
			local stderr = vim.trim(result.stderr or "")
			callback(nil, stderr ~= "" and stderr or "herdr request failed")
			return
		end
		callback(decoded.result or {})
	end))
	if not ok then
		vim.schedule(function()
			callback(nil, tostring(err))
		end)
	end
end

function M.list_agents(callback)
	run({ "agent", "list" }, function(result, err, code)
		if not result then
			callback(nil, err, code)
			return
		end
		callback(type(result.agents) == "table" and result.agents or {})
	end)
end

local function inside(path, root)
	if type(path) ~= "string" or path == "" then
		return false
	end
	path = vim.fs.normalize(path)
	root = vim.fs.normalize(root)
	return path == root or vim.startswith(path, root .. "/")
end

--- Agents working inside `repo_root`, same-workspace ones first; other workspaces only when none match.
function M.candidates(agents, opts)
	local in_repo = {}
	for _, agent in ipairs(agents or {}) do
		if type(agent) == "table"
			and type(agent.pane_id) == "string"
			and type(agent.agent) == "string"
			and agent.pane_id ~= opts.self_pane
			and (inside(agent.foreground_cwd, opts.repo_root) or inside(agent.cwd, opts.repo_root))
		then
			table.insert(in_repo, agent)
		end
	end

	local same_workspace = {}
	if opts.workspace_id then
		for _, agent in ipairs(in_repo) do
			if agent.workspace_id == opts.workspace_id then
				table.insert(same_workspace, agent)
			end
		end
	end
	local list = #same_workspace > 0 and same_workspace or in_repo
	table.sort(list, function(a, b)
		return a.pane_id < b.pane_id
	end)
	return list
end

function M.label(agent)
	local title = agent.name or agent.terminal_title_stripped or ""
	return string.format("%s %s [%s] %s", agent.agent, agent.pane_id, agent.agent_status or "unknown", title)
end

function M.remember(session_name, pane_id)
	remembered[session_name] = pane_id
end

function M.remembered(session_name, candidates)
	local pane_id = session_name and remembered[session_name]
	for _, agent in ipairs(candidates) do
		if agent.pane_id == pane_id then
			return agent
		end
	end
	return nil
end

function M.prompt(pane_id, text, callback)
	run({ "agent", "prompt", pane_id, text }, callback)
end

return M
