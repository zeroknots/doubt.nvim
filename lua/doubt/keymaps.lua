-- Leader mappings mirror the command surface for quick review workflows.
local claims = require("doubt.claims")

local M = {}

local registered_keymaps = {}

local DEFAULT_DESC = {
	export = "Copy doubt export for agent handoff",
	export_picker = "Pick a doubt export template for agent handoff",
	agent_instructions = "Copy doubt agent review instructions",
	delete_claim = "Delete doubt claim nearest to cursor",
	undo_delete_claim = "Restore most recently deleted doubt claim",
	edit_kind = "Change doubt claim kind nearest to cursor",
	edit_note = "Change doubt claim note nearest to cursor",
	toggle_claim = "Toggle doubt claim note nearest to cursor",
	toggle_notes = "Toggle doubt claim text descriptions",
	clear_buffer = "Clear doubt state for current buffer",
	panel = "Toggle doubt panel",
	review = "Review current branch against its base",
	send = "Send doubt export to the herdr agent",
	session_new = "Start a new doubt session",
	session_resume = "Resume a saved doubt session",
	stop_session = "Stop the active doubt session",
	refresh = "Refresh doubt decorations and panel",
}

function M.register(api, opts)
	for action, mapping in pairs(registered_keymaps) do
		for _, entry in ipairs(mapping) do
			pcall(vim.keymap.del, entry.mode, entry.lhs)
		end
		registered_keymaps[action] = nil
	end

	if opts == false then
		return
	end

	opts = opts or {}
	opts.claims = opts.claims or {}
	for _, kind in ipairs(claims.list_claim_kinds()) do
		if opts[kind] ~= nil and opts.claims[kind] == nil then
			opts.claims[kind] = opts[kind]
		end
	end

	local function set_keymap(action, mode, lhs, callback, desc)
		vim.keymap.set(mode, lhs, callback, { desc = desc, silent = true })
		registered_keymaps[action] = registered_keymaps[action] or {}
		table.insert(registered_keymaps[action], {
			lhs = lhs,
			mode = mode,
		})
	end

	for _, kind in ipairs(claims.list_claim_kinds()) do
		local mapping = opts.claims[kind]
		if mapping then
			local desc = claims.meta(kind).description
			set_keymap(kind, "n", mapping, function()
				api.claim_range(kind, {})
			end, desc)

			set_keymap(kind, "x", mapping, function()
				api.claim_visual(kind, {})
			end, desc)
		end
	end

	if opts.export then
		set_keymap("export", "n", opts.export, function()
			api.copy_export_async()
		end, DEFAULT_DESC.export)
	end

	if opts.agent_instructions then
		set_keymap("agent_instructions", "n", opts.agent_instructions, function()
			api.copy_agent_instructions()
		end, DEFAULT_DESC.agent_instructions)
	end

	if opts.delete_claim then
		set_keymap("delete_claim", "n", opts.delete_claim, function()
			api.delete_nearest_claim()
		end, DEFAULT_DESC.delete_claim)
	end

	if opts.undo_delete_claim then
		set_keymap("undo_delete_claim", "n", opts.undo_delete_claim, function()
			api.undo_deleted_claim()
		end, DEFAULT_DESC.undo_delete_claim)
	end

	if opts.edit_kind then
		set_keymap("edit_kind", "n", opts.edit_kind, function()
			api.edit_nearest_claim_kind()
		end, DEFAULT_DESC.edit_kind)
	end

	if opts.edit_note then
		set_keymap("edit_note", "n", opts.edit_note, function()
			api.edit_nearest_claim_note()
		end, DEFAULT_DESC.edit_note)
	end

	if opts.toggle_claim then
		set_keymap("toggle_claim", "n", opts.toggle_claim, function()
			api.toggle_nearest_claim()
		end, DEFAULT_DESC.toggle_claim)
	end

	if opts.toggle_notes then
		set_keymap("toggle_notes", "n", opts.toggle_notes, function()
			api.toggle_inline_notes()
		end, DEFAULT_DESC.toggle_notes)
	end

	local export_picker = opts.export_picker
	if export_picker == nil then
		export_picker = "<leader>DE"
	end
	if export_picker then
		set_keymap("export_picker", "n", export_picker, function()
			api.copy_export_with_picker_async()
		end, DEFAULT_DESC.export_picker)
	end

	if opts.clear_buffer then
		set_keymap("clear_buffer", "n", opts.clear_buffer, function()
			api.clear_buffer()
		end, DEFAULT_DESC.clear_buffer)
	end

	if opts.panel then
		set_keymap("panel", "n", opts.panel, function()
			api.open_panel()
		end, DEFAULT_DESC.panel)
	end

	if opts.review then
		set_keymap("review", "n", opts.review, function()
			api.start_review()
		end, DEFAULT_DESC.review)
	end

	if opts.send then
		set_keymap("send", "n", opts.send, function()
			api.send_export()
		end, DEFAULT_DESC.send)
	end

	if opts.session_new then
		set_keymap("session_new", "n", opts.session_new, function()
			api.start_session()
		end, DEFAULT_DESC.session_new)
	end

	if opts.session_resume then
		set_keymap("session_resume", "n", opts.session_resume, function()
			api.resume_session()
		end, DEFAULT_DESC.session_resume)
	end

	if opts.stop_session then
		set_keymap("stop_session", "n", opts.stop_session, function()
			api.stop_session()
		end, DEFAULT_DESC.stop_session)
	end

	if opts.refresh then
		set_keymap("refresh", "n", opts.refresh, function()
			api.refresh()
		end, DEFAULT_DESC.refresh)
	end
end

return M
