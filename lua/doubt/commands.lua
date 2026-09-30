-- User command registration stays separate from the core API so command UX can evolve independently.
local claims = require("doubt.claims")

local M = {}

local registered_claim_commands = {}

local function command_note(args)
	if not args or args == "" then
		return nil
	end

	return args
end

local function complete_export_template(api, arg_lead)
	local matches = {}

	for _, name in ipairs(api.list_export_templates()) do
		if arg_lead == "" or vim.startswith(name, arg_lead) then
			table.insert(matches, name)
		end
	end

	return matches
end

local function complete_claim_kind(arg_lead)
	local matches = {}

	for _, kind in ipairs(claims.list_claim_kinds()) do
		if arg_lead == "" or vim.startswith(kind, arg_lead) then
			table.insert(matches, kind)
		end
	end

	return matches
end

local function replace_command(name, callback, opts)
	pcall(vim.api.nvim_del_user_command, name)
	vim.api.nvim_create_user_command(name, callback, opts)
end

function M.register(api)
	for _, name in ipairs(registered_claim_commands) do
		pcall(vim.api.nvim_del_user_command, name)
	end
	registered_claim_commands = {}

	local function register_claim_command(kind)
		local meta = claims.meta(kind)
		local name = "Doubt" .. meta.command
		replace_command(name, function(command_opts)
			command_opts.note = command_note(command_opts.args)
			api.claim_range(kind, command_opts)
		end, {
			desc = meta.description,
			nargs = "*",
			range = true,
		})
		table.insert(registered_claim_commands, name)
	end

	for _, kind in ipairs(claims.list_claim_kinds()) do
		register_claim_command(kind)
	end

	replace_command("DoubtClaim", function(command_opts)
		local args = vim.split(vim.trim(command_opts.args or ""), "%s+", { plain = false, trimempty = true })
		local kind = args[1]
		if not kind then
			vim.notify("Claim kind is required", vim.log.levels.WARN, { title = "doubt.nvim" })
			return
		end

		table.remove(args, 1)
		command_opts.note = command_note(table.concat(args, " "))
		api.claim_range(kind, command_opts)
	end, {
		desc = "Add a configured doubt claim kind",
		nargs = "+",
		range = true,
		complete = function(arg_lead, cmd_line)
			local parts = vim.split(cmd_line or "", "%s+", { plain = false, trimempty = true })
			if #parts <= 2 then
				return complete_claim_kind(arg_lead)
			end
			return {}
		end,
	})

	replace_command("DoubtClaimDelete", function()
		api.delete_nearest_claim()
	end, { desc = "Delete the claim nearest to the cursor" })

	replace_command("DoubtClaimKind", function(command_opts)
		local kind = vim.trim(command_opts.args or "")
		if kind == "" then
			vim.notify("Claim kind is required", vim.log.levels.WARN, { title = "doubt.nvim" })
			return
		end

		api.edit_nearest_claim_kind({ kind = kind })
	end, {
		desc = "Change the nearest claim kind",
		nargs = 1,
		complete = function(arg_lead)
			return complete_claim_kind(arg_lead)
		end,
	})

	replace_command("DoubtClaimNote", function(command_opts)
		api.edit_nearest_claim_note({ note = command_note(command_opts.args) })
	end, {
		desc = "Change the nearest claim note",
		nargs = "*",
	})

	replace_command("DoubtClaimToggle", function()
		api.toggle_nearest_claim()
	end, { desc = "Toggle the nearest claim note" })

	replace_command("DoubtNotesToggle", function()
		api.toggle_inline_notes()
	end, { desc = "Toggle doubt claim text descriptions" })

	replace_command("DoubtClearBuffer", function()
		api.clear_buffer()
	end, { desc = "Clear doubt state for the current buffer" })

	replace_command("DoubtPanel", function()
		api.open_panel()
	end, { desc = "Toggle the doubt review panel" })

	replace_command("DoubtRefresh", function()
		api.refresh()
	end, { desc = "Refresh doubt decorations and panel" })

	replace_command("DoubtHealthcheck", function()
		api.healthcheck()
	end, { desc = "Run doubt startup healthcheck report" })

	replace_command("DoubtExportXml", function()
		api.export_xml()
	end, { desc = "Open the active doubt session as raw XML handoff" })

	replace_command("DoubtExport", function(command_opts)
		api.copy_export_async({ template = command_note(command_opts.args) })
	end, {
		desc = "Copy the active doubt session for agent handoff",
		nargs = "?",
		complete = function(arg_lead)
			return complete_export_template(api, arg_lead)
		end,
	})

	replace_command("DoubtExportFilter", function()
		api.copy_filtered_export()
	end, {
		desc = "Copy selected doubt claim types as raw XML",
		nargs = 0,
	})

	replace_command("DoubtAgentInstructionsCopy", function()
		api.copy_agent_instructions()
	end, {
		desc = "Copy doubt workspace review instructions for agents",
		nargs = 0,
	})

	replace_command("DoubtState", function()
		api.open_state_file()
	end, {
		desc = "Open the persisted doubt state JSON file",
		nargs = 0,
	})

	replace_command("DoubtSessionNew", function(command_opts)
		api.start_session({ name = command_note(command_opts.args) })
	end, {
		desc = "Start or switch to a doubt session",
		nargs = "?",
	})

	replace_command("DoubtSessionResume", function(command_opts)
		api.resume_session({ name = command_note(command_opts.args) })
	end, {
		desc = "Resume a saved doubt session",
		nargs = "?",
	})

	replace_command("DoubtSessionStop", function()
		api.stop_session()
	end, { desc = "Stop the active doubt session" })

	replace_command("DoubtSessionDelete", function(command_opts)
		api.delete_session({ name = command_note(command_opts.args) })
	end, {
		desc = "Delete a saved doubt session",
		nargs = "?",
	})

	replace_command("DoubtSessionRename", function(command_opts)
		local args = vim.split(vim.trim(command_opts.args or ""), "%s+", { plain = false, trimempty = true })
		api.rename_session({
			name = args[1],
			new_name = args[2],
		})
	end, {
		desc = "Rename a saved doubt session",
		nargs = "*",
	})

	replace_command("DoubtSend", function(command_opts)
		api.send_export({ template = command_note(command_opts.args) })
	end, {
		complete = function(arg_lead)
			return complete_export_template(api, arg_lead)
		end,
		desc = "Send the doubt export to the herdr agent working in this repository",
		nargs = "?",
	})

	replace_command("DoubtReview", function(command_opts)
		api.start_review({ base = command_note(command_opts.args) })
	end, {
		desc = "Review the current branch against its base in a doubt session",
		nargs = "?",
	})

	replace_command("DoubtWorkspaceSessionNew", function(command_opts)
		api.start_workspace_session({ name = command_note(command_opts.args) })
	end, {
		desc = "Start or switch to a workspace doubt session",
		nargs = "?",
	})

	replace_command("DoubtWorkspaceSessionResume", function(command_opts)
		api.resume_workspace_session({ name = command_note(command_opts.args) })
	end, {
		desc = "Resume a workspace doubt session",
		nargs = "?",
	})

	replace_command("DoubtWorkspaceSessionDelete", function(command_opts)
		api.delete_workspace_session({ name = command_note(command_opts.args) })
	end, {
		desc = "Delete a workspace doubt session",
		nargs = "?",
	})

	replace_command("DoubtWorkspaceSessionRename", function(command_opts)
		local args = vim.split(vim.trim(command_opts.args or ""), "%s+", { plain = false, trimempty = true })
		api.rename_workspace_session({
			name = args[1],
			new_name = args[2],
		})
	end, {
		desc = "Rename a workspace doubt session",
		nargs = "*",
	})
end

return M
