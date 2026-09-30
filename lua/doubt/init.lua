-- Public entrypoint that wires together config, state, rendering, and commands.
local claims = require("doubt.claims")
local agent_instructions = require("doubt.agent_instructions")
local context = require("doubt.app.context")
local session_ui = require("doubt.app.session_ui")
local commands = require("doubt.commands")
local config = require("doubt.config")
local diff_viewer = require("doubt.diff_viewer")
local export = require("doubt.export")
local healthcheck = require("doubt.healthcheck")
local input = require("doubt.input")
local inline_editor = require("doubt.inline_editor")
local keymaps = require("doubt.keymaps")
local panel = require("doubt.panel")
local preferences = require("doubt.preferences")
local pr_review = require("doubt.pr_review")
local render = require("doubt.render")
local review_runs = require("doubt.review_runs")
local state = require("doubt.state")

local M = {}

local deleted_claim_stack = {}
local MAX_DELETED_CLAIMS = 50
local export_snapshot = nil
local export_snapshot_token = 0
local export_write_generation = 0
local EXPORT_SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local ctx = context.new({
	config = config,
	panel = panel,
	render = render,
	review_runs = review_runs,
	state = state,
})

local clear_expanded_claim = ctx.clear_expanded_claim
local clear_focused_claim = ctx.clear_focused_claim
local set_focused_claim = ctx.set_focused_claim
local set_expanded_claim = ctx.set_expanded_claim
local clear_live_edit_timers = ctx.clear_live_edit_timers
local schedule_live_edit_refresh = ctx.schedule_live_edit_refresh
local stop_live_edit_timer = ctx.stop_live_edit_timer

local function prompt_session_name(opts, callback)
	session_ui.prompt_session_name(config, input, state, ctx, opts, callback)
end

local function with_active_session(callback)
	session_ui.with_active_session(state, prompt_session_name, M.start_session, callback)
end

local function confirm(message)
	return session_ui.confirm(message)
end

local function current_cursor_position()
	return session_ui.current_cursor_position()
end

local function trim_deleted_claim_stack()
	while #deleted_claim_stack > MAX_DELETED_CLAIMS do
		table.remove(deleted_claim_stack, 1)
	end
end

local function push_deleted_claim(path, claim)
	if type(path) ~= "string" or type(claim) ~= "table" then
		return
	end

	table.insert(deleted_claim_stack, {
		claim = vim.deepcopy(claim),
		path = path,
		session_name = state.active_session_name(),
		session_source = state.active_session_source(),
		workspace_key = ctx.normalize_path(vim.fn.getcwd()),
	})
	trim_deleted_claim_stack()
end

local function add_claim(kind, opts)
	opts = opts or {}
	local path = ctx.current_path(opts.bufnr)
	if not path then
		ctx.notify("Current buffer has no file path", vim.log.levels.WARN)
		return
	end

	-- Claims are always stored in normalized form before any UI refresh happens.
	local file_state = state.ensure_file_entry(path)
	if not file_state then
		ctx.notify("No active doubt session", vim.log.levels.INFO)
		return
	end
	local start_line, start_col, end_line, end_col =
		claims.normalize_position_range(opts.start_line, opts.start_col, opts.end_line, opts.end_col)
	local normalized = claims.normalize_claim({
		id = claims.next_session_claim_id(state.current_files(), kind),
		kind = claims.normalize_claim_kind(kind),
		start_line = start_line,
		start_col = start_col,
		end_line = end_line,
		end_col = end_col,
		note = claims.normalize_note(opts.note),
		freshness = "fresh",
		anchor = claims.build_buffer_anchor(opts.bufnr, start_line, start_col, end_line, end_col),
	})
	table.insert(file_state.claims, normalized)
	claims.sort_claims(file_state.claims)

	state.save(config.get(), ctx.notify)
	ctx.refresh_ui(opts.bufnr)
end

local function claim_reference_items(exclude_id)
	local items = {}
	local paths = vim.tbl_keys(state.current_files() or {})
	table.sort(paths)
	for _, path in ipairs(paths) do
		for _, claim in ipairs((state.current_files()[path] or {}).claims or {}) do
			if claim.id ~= exclude_id then
				local note = (claim.note or ""):gsub("%s+", " ")
				if vim.fn.strchars(note) > 60 then
					note = vim.fn.strcharpart(note, 0, 57) .. "..."
				end
				table.insert(items, {
					id = claim.id,
					label = string.format(
						"%-9s %s:%d  %s",
						(claim.kind or "claim"):upper(),
						vim.fn.fnamemodify(path, ":."),
						(claim.start_line or 0) + 1,
						note
					),
				})
			end
		end
	end
	return items
end

local function resolve_note(kind, opts, callback)
	opts = opts or {}
	if opts.note ~= nil then
		callback(claims.normalize_note(opts.note))
		return
	end

	local input_config = config.get().input or {}
	local line = opts.line
	local col = opts.col
	if line == nil or col == nil then
		line, col = current_cursor_position()
	end
	if input_config.mode ~= "popup" then
		local claim = claims.normalize_claim({
			id = opts.id or ("draft-" .. claims.new_claim_id():sub(7)),
			kind = kind,
			start_line = line,
			start_col = col,
			end_line = opts.end_line or line,
			end_col = opts.end_col or col,
			note = opts.default or "",
			freshness = "fresh",
		})
		if inline_editor.open({
			bufnr = opts.bufnr or vim.api.nvim_get_current_buf(),
			claim = claim,
			claim_references = claim_reference_items(opts.id),
			default = opts.default,
			discard_empty = opts.discard_empty == true,
			draft = opts.draft == true,
			on_submit = callback,
			winid = opts.winid,
		}) then
			return
		end
	end

	local prompt = (claims.meta(kind) or {}).prompt or ((input_config.prompts or {})[kind])
	input.ask_note({
		border = input_config.border,
		col = col,
		default = opts.default,
		height = input_config.height,
		line = line,
		claim_references = claim_reference_items(opts.id),
		prompt = prompt,
		title = claims.normalize_claim_kind(kind),
		width = input_config.width,
	}, function(note, cancelled)
		if cancelled then
			return
		end

		callback(claims.normalize_note(note))
	end)
end

local function resolve_nearest_claim(opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local path = ctx.current_path(bufnr)
	if not path then
		ctx.notify("Current buffer has no file path", vim.log.levels.WARN)
		return nil
	end

	if not state.has_active_session() then
		ctx.notify("No active doubt session", vim.log.levels.INFO)
		return nil
	end

	local file_state = state.current_files()[path]
	local claim_list = file_state and file_state.claims or nil
	if not claim_list or vim.tbl_isempty(claim_list) then
		ctx.notify("No claims in the current file", vim.log.levels.INFO)
		return nil
	end

	local line, col = current_cursor_position()
	local claim = claims.find_nearest_claim(claim_list, line, col)
	if not claim then
		ctx.notify("No claim found near the cursor", vim.log.levels.INFO)
		return nil
	end

	return {
		bufnr = bufnr,
		claim = claim,
		path = path,
	}
end

local function claim_range(kind, opts)
	if not claims.has_claim_kind(kind) then
		ctx.notify("Unknown claim kind", vim.log.levels.WARN)
		return
	end

	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local start_line, start_col, end_line, end_col = claims.current_span_from_command(opts, bufnr)
	with_active_session(function()
		resolve_note(kind, vim.tbl_extend("force", opts, {
			bufnr = bufnr,
			col = start_col,
			discard_empty = true,
			draft = true,
			end_col = end_col,
			end_line = end_line,
			line = start_line,
		}), function(note)
			add_claim(kind, {
				bufnr = bufnr,
				start_line = start_line,
				start_col = start_col,
				end_line = end_line,
				end_col = end_col,
				note = note,
			})
		end)
	end)
end

local function leave_visual_mode()
	local keys = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
	vim.api.nvim_feedkeys(keys, "x", false)
end

local function claim_visual(kind, opts)
	if not claims.has_claim_kind(kind) then
		ctx.notify("Unknown claim kind", vim.log.levels.WARN)
		return
	end

	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local start_line, start_col, end_line, end_col = claims.current_visual_span(bufnr)
	leave_visual_mode()
	with_active_session(function()
		resolve_note(kind, vim.tbl_extend("force", opts, {
			bufnr = bufnr,
			col = start_col,
			discard_empty = true,
			draft = true,
			end_col = end_col,
			end_line = end_line,
			line = start_line,
		}), function(note)
			add_claim(kind, {
				bufnr = bufnr,
				start_line = start_line,
				start_col = start_col,
				end_line = end_line,
				end_col = end_col,
				note = note,
			})
		end)
	end)
end

function M.claim_range(kind, opts)
	claim_range(kind, opts)
end

function M.claim_visual(kind, opts)
	claim_visual(kind, opts)
end

function M.question_range(opts)
	claim_range("question", opts)
end

function M.reject_range(opts)
	claim_range("reject", opts)
end

function M.question_visual(opts)
	claim_visual("question", opts)
end

function M.reject_visual(opts)
	claim_visual("reject", opts)
end

function M.clear_buffer()
	inline_editor.close()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = ctx.current_path(bufnr)
	if not path then
		ctx.notify("Current buffer has no file path", vim.log.levels.WARN)
		return
	end

	local files = state.current_files()
	files[path] = nil
	if ctx.expanded_claim and ctx.expanded_claim.path == path then
		clear_expanded_claim()
	end
	if ctx.focused_claim and ctx.focused_claim.path == path then
		clear_focused_claim()
	end
	state.save(config.get(), ctx.notify)
	render.clear_buffer_claims(ctx, bufnr)
	ctx.refresh_ui(bufnr)
end

function M.delete_claim(opts)
	opts = opts or {}
	local claim = state.find_claim(opts.path, opts.id)
	if not confirm("Delete doubt claim?") then
		return
	end
	local editor = inline_editor.status()
	if editor.active and not editor.draft and editor.claim.id == opts.id then
		inline_editor.close()
	end

	if not state.delete_claim(opts.path, opts.id) then
		ctx.notify("Unable to delete claim", vim.log.levels.WARN)
		return
	end

	push_deleted_claim(opts.path, claim)

	if ctx.expanded_claim and ctx.expanded_claim.path == opts.path and ctx.expanded_claim.id == opts.id then
		clear_expanded_claim()
	end
	if ctx.focused_claim and ctx.focused_claim.path == opts.path and ctx.focused_claim.id == opts.id then
		clear_focused_claim()
	end

	state.save(config.get(), ctx.notify)
	ctx.refresh_ui(opts.bufnr)
end

function M.undo_deleted_claim()
	local session_name = state.active_session_name()
	if not session_name then
		ctx.notify("No active doubt session", vim.log.levels.INFO)
		return
	end

	local session_source = state.active_session_source()
	local workspace_key = ctx.normalize_path(vim.fn.getcwd())
	for idx = #deleted_claim_stack, 1, -1 do
		local entry = deleted_claim_stack[idx]
		if entry.session_name == session_name and entry.session_source == session_source and entry.workspace_key == workspace_key then
			table.remove(deleted_claim_stack, idx)
			local file_state = state.ensure_file_entry(entry.path)
			if file_state and entry.claim and not state.find_claim(entry.path, entry.claim.id) then
				table.insert(file_state.claims, vim.deepcopy(entry.claim))
				claims.sort_claims(file_state.claims)
				state.save(config.get(), ctx.notify)
				ctx.refresh_ui()
				ctx.notify("Restored deleted doubt claim")
				return
			end
		end
	end

	ctx.notify("No recently deleted claim to restore", vim.log.levels.INFO)
end

function M.delete_nearest_claim(opts)
	local target = resolve_nearest_claim(opts)
	if not target then
		return
	end

	M.delete_claim({
		bufnr = target.bufnr,
		id = target.claim.id,
		path = target.path,
	})
end

function M.edit_nearest_claim_kind(opts)
	opts = opts or {}
	local target = resolve_nearest_claim(opts)
	if not target then
		return
	end

	local function apply_kind(kind)
		if not claims.has_claim_kind(kind) then
			ctx.notify("Unknown claim kind", vim.log.levels.WARN)
			return
		end

		if not state.update_claim(target.path, target.claim.id, { kind = kind }) then
			ctx.notify("Unable to update claim", vim.log.levels.WARN)
			return
		end
		state.save(config.get(), ctx.notify)
		ctx.refresh_ui(target.bufnr)
	end

	if opts.kind then
		apply_kind(opts.kind)
		return
	end

	local available_kinds = {}
	for _, kind in ipairs(claims.list_claim_kinds()) do
		if kind ~= target.claim.kind then
			table.insert(available_kinds, kind)
		end
	end

	if vim.tbl_isempty(available_kinds) then
		ctx.notify("No other claim kinds available", vim.log.levels.INFO)
		return
	end

	vim.ui.select(available_kinds, {
		prompt = "Change claim kind",
	}, function(kind)
		if not kind then
			return
		end

		apply_kind(kind)
	end)
end

function M.edit_nearest_claim_note(opts)
	opts = opts or {}
	local target = resolve_nearest_claim(opts)
	if not target then
		return
	end

	local function apply_note(note)
		if not state.update_claim(target.path, target.claim.id, { note = note }) then
			ctx.notify("Unable to update claim", vim.log.levels.WARN)
			return
		end

		state.save(config.get(), ctx.notify)
		ctx.refresh_ui(target.bufnr)
	end

	if opts.note ~= nil then
		apply_note(claims.normalize_note(opts.note))
		return
	end

	local input_config = config.get().input or {}
	if input_config.mode ~= "popup" and inline_editor.open({
		bufnr = target.bufnr,
		claim = target.claim,
		claim_references = claim_reference_items(target.claim.id),
		default = target.claim.note,
		on_submit = function(note)
			apply_note(claims.normalize_note(note))
		end,
		winid = vim.api.nvim_get_current_win(),
	}) then
		return
	end

	local prompt = (claims.meta(target.claim.kind) or {}).prompt or ((input_config.prompts or {})[target.claim.kind])
	input.ask_note({
		border = input_config.border,
		col = target.claim.start_col,
		default = target.claim.note,
		height = input_config.height,
		line = target.claim.start_line,
		claim_references = claim_reference_items(target.claim.id),
		prompt = prompt,
		title = claims.normalize_claim_kind(target.claim.kind),
		width = input_config.width,
		winid = vim.api.nvim_get_current_win(),
	}, function(note, cancelled)
		if cancelled then
			return
		end

		apply_note(claims.normalize_note(note))
	end)
end

function M.toggle_nearest_claim(opts)
	opts = opts or {}
	local target = resolve_nearest_claim(opts)
	if not target then
		return
	end

	if ctx.is_claim_expanded(target.path, target.claim) then
		clear_expanded_claim()
	else
		set_expanded_claim(target.path, target.claim.id)
	end

	ctx.refresh_ui(target.bufnr)
end

function M.toggle_inline_notes()
	local layout = ctx.toggle_inline_notes()
	preferences.save(config.get(), { inline_notes_layout = layout }, ctx.notify)
	if layout == "inline" then
		clear_expanded_claim()
	end

	ctx.refresh_ui()
	ctx.notify(layout == "block" and "Doubt claim notes shown as blocks" or "Doubt claim notes shown inline", vim.log.levels.INFO)
	return layout
end

function M.delete_file(opts)
	opts = opts or {}

	if not state.delete_file(opts.path) then
		ctx.notify("Unable to delete file", vim.log.levels.WARN)
		return
	end

	if ctx.focused_claim and ctx.focused_claim.path == opts.path then
		clear_focused_claim()
	end

	state.save(config.get(), ctx.notify)
	ctx.refresh_ui()
end

function M.focus_claim(opts)
	opts = opts or {}
	local session_name = state.active_session_name()
	if not session_name or session_name ~= opts.session_name then
		return
	end

	local path = ctx.normalize_path(opts.path)
	if not path or type(opts.id) ~= "string" or opts.id == "" then
		return
	end

	local current = ctx.focused_claim
	if current and current.session_name == session_name and current.path == path and current.id == opts.id then
		return
	end

	set_focused_claim(session_name, path, opts.id)
	ctx.refresh_ui()
end

function M.clear_focused_claim()
	if not ctx.focused_claim then
		return
	end

	clear_focused_claim()
	ctx.refresh_ui()
end

function M.open_panel()
	ctx.refresh_review_run_inspection()
	panel.open(ctx)
end

function M.open_claim_diff(opts)
	opts = opts or {}
	if not state.has_active_session() then
		ctx.notify("No active doubt session", vim.log.levels.INFO)
		return
	end
	if type(opts.id) ~= "string" or opts.id == "" or type(opts.path) ~= "string" then
		ctx.notify("Select a doubt claim to inspect its changes", vim.log.levels.INFO)
		return
	end
	if not state.find_claim(opts.path, opts.id) then
		ctx.notify("Unable to find the selected doubt claim", vim.log.levels.WARN)
		return
	end

	local result, err = review_runs.claim_diff({
		claim_id = opts.id,
		inspection = ctx.review_run_inspection(),
		session_name = state.active_session_name(),
		session_source = state.active_session_source(),
		workspace = vim.fn.getcwd(),
	})
	if not result then
		ctx.notify(err, vim.log.levels.INFO)
		return
	end

	local opened, viewer_error = diff_viewer.open({
		claim_id = opts.id,
		notify = ctx.notify,
		result = result,
		viewer = (config.get().review_runs or {}).diff_viewer,
	})
	if not opened then
		ctx.notify(viewer_error or "Unable to open doubt claim diff", vim.log.levels.WARN)
		return
	end
	if result.unattributed_count > 0 then
		ctx.notify(string.format(
			"Opened claim diff; %d review-run %s remain unattributed",
			result.unattributed_count,
			result.unattributed_count == 1 and "hunk" or "hunks"
		), vim.log.levels.WARN)
	end
	return result
end

local function refresh_active_session_claims()
	local result = state.classify_current_session_claims()
	if result.changed_file_count > 0 then
		state.save(config.get(), ctx.notify)
	end

	return result
end

function M.refresh()
	refresh_active_session_claims()
	ctx.refresh_review_run_inspection()
	ctx.refresh_ui()
end

local function build_export_payload(opts)
	opts = opts or {}
	local session_name = state.active_session_name()
	if not session_name then
		ctx.notify("No active doubt session", vim.log.levels.INFO)
		return nil
	end

	refresh_active_session_claims()

	local files = state.current_files()
	local export_files = files
	local export_stats = {
		exportable_claim_count = 0,
		exportable_file_count = 0,
		skipped_stale_claims = 0,
	}

	local inspection = opts.inspection
	if opts.trusted_only then
		if not opts.skip_inspection_refresh then
			inspection = ctx.refresh_review_run_inspection()
		end
		local review_statuses = inspection and inspection.statuses or {}
		export_files, export_stats = export.select_trusted_files(files, review_statuses)
	else
		export_stats.exportable_claim_count = 0
		for _, file_state in pairs(export_files) do
			export_stats.exportable_claim_count = export_stats.exportable_claim_count + #((file_state or {}).claims or {})
		end
		export_stats.exportable_file_count = vim.tbl_count(export_files)
	end

	local xml = export.build_session_xml(session_name, export_files)

	local review_run = nil
	local review_run_deferred = false
	if opts.create_review_run and export_stats.exportable_claim_count > 0 then
		local baseline_tree = opts.baseline_tree or (inspection and inspection.current_tree) or nil
		if opts.defer_missing_baseline and not baseline_tree then
			review_run_deferred = true
		else
			review_run = review_runs.create({
				baseline_tree = baseline_tree,
				files = export_files,
				session_name = session_name,
				session_source = state.active_session_source(),
				workspace = vim.fn.getcwd(),
			})
			if review_run then
				ctx.invalidate_review_run_inspection()
				review_run.protocol_text = review_runs.protocol_text(review_run)
				xml = export.build_session_xml(session_name, export_files, nil, review_run)
			end
		end
	end
	if not xml then
		ctx.notify("Unable to export doubt session", vim.log.levels.WARN)
		return nil
	end

	local text, err, template_name = export.build_export_text({
		export_config = config.get().export,
		files = export_files,
		review_context = pr_review.context_text(session_name),
		review_run = review_run,
		session_name = session_name,
		template = opts.template,
		xml = xml,
	})
	if not text then
		ctx.notify(err, vim.log.levels.WARN)
		return nil
	end

	return {
		export_stats = export_stats,
		exportable_claim_count = export_stats.exportable_claim_count,
		session_name = session_name,
		files = files,
		export_files = export_files,
		template_name = template_name,
		review_run = review_run,
		text = text,
		xml = xml,
		inspection = inspection,
		review_run_deferred = review_run_deferred,
	}
end

local function pluralize_claim(count)
	if count == 1 then
		return "claim"
	end

	return "claims"
end

local function skipped_claims_summary(stats)
	local parts = {}
	local stale = (stats or {}).skipped_stale_claims or 0
	local reviewed = (stats or {}).skipped_reviewed_claims or 0
	if stale > 0 then
		table.insert(parts, string.format("%d stale %s", stale, pluralize_claim(stale)))
	end
	if reviewed > 0 then
		table.insert(parts, string.format("%d previously reviewed %s", reviewed, pluralize_claim(reviewed)))
	end
	return table.concat(parts, ", ")
end

local function count_claim_kinds(files)
	local counts = {}
	for _, file_state in pairs(files or {}) do
		for _, claim in ipairs((file_state or {}).claims or {}) do
			local kind = claims.normalize_claim_kind(claim.kind)
			counts[kind] = (counts[kind] or 0) + 1
		end
	end
	return counts
end

local function copy_export_payload(payload)
	if not payload then
		return
	end

	local skipped = skipped_claims_summary(payload.export_stats)
	if payload.exportable_claim_count == 0 then
		local message = "No exportable claims remain"
		if skipped ~= "" then
			message = message .. "; skipped " .. skipped
		end
		ctx.notify(message, vim.log.levels.WARN)
		return
	end

	local export_config = config.get().export or {}
	local register = export_config.register or "+"
	vim.fn.setreg(register, payload.text)
	if skipped ~= "" then
		ctx.notify(
			string.format(
				"Copied doubt export to %s (%s, skipped %s)",
				register,
				payload.template_name,
				skipped
			)
		)
	else
		ctx.notify(string.format("Copied doubt export to %s (%s)", register, payload.template_name))
	end
	return payload.text
end

local function stop_export_spinner(snapshot)
	if not snapshot or export_snapshot ~= snapshot then
		return
	end
	export_snapshot = nil
	if snapshot.timer then
		snapshot.timer:stop()
		if not snapshot.timer:is_closing() then
			snapshot.timer:close()
		end
	end
	vim.api.nvim_echo({ { "" } }, false, {})
end

local function start_export_spinner()
	export_snapshot_token = export_snapshot_token + 1
	local snapshot = {
		frame = 0,
		session_name = state.active_session_name(),
		session_source = state.active_session_source(),
		token = export_snapshot_token,
		workspace = ctx.normalize_path(vim.fn.getcwd()),
		write_generation = export_write_generation,
	}
	snapshot.timer = vim.uv.new_timer()
	export_snapshot = snapshot
	snapshot.timer:start(0, 100, vim.schedule_wrap(function()
		if export_snapshot ~= snapshot then
			return
		end
		snapshot.frame = (snapshot.frame % #EXPORT_SPINNER_FRAMES) + 1
		vim.api.nvim_echo({
			{ "Preparing doubt export... " .. EXPORT_SPINNER_FRAMES[snapshot.frame], "ModeMsg" },
		}, false, {})
	end))
	return snapshot
end

function M.copy_export(opts)
	opts = opts or {}
	local payload = build_export_payload(vim.tbl_extend("force", opts, {
		create_review_run = true,
		trusted_only = true,
	}))
	return copy_export_payload(payload)
end

function M.copy_export_async(opts)
	opts = opts or {}
	if export_snapshot then
		ctx.notify("A doubt export is already being prepared", vim.log.levels.INFO)
		return
	end

	local payload = build_export_payload(vim.tbl_extend("force", opts, {
		create_review_run = true,
		defer_missing_baseline = true,
		trusted_only = true,
	}))
	if not payload or payload.exportable_claim_count == 0 or not payload.review_run_deferred then
		return copy_export_payload(payload)
	end

	local snapshot = start_export_spinner()
	review_runs.capture_tree_async({ workspace = snapshot.workspace }, function(tree, err)
		if export_snapshot ~= snapshot then
			return
		end
		stop_export_spinner(snapshot)
		if snapshot.write_generation ~= export_write_generation then
			ctx.notify("Files changed while preparing the doubt export; run :DoubtExport again", vim.log.levels.WARN)
			return
		end
		if snapshot.workspace ~= ctx.normalize_path(vim.fn.getcwd())
			or snapshot.session_name ~= state.active_session_name()
			or snapshot.session_source ~= state.active_session_source()
		then
			ctx.notify("The active doubt session changed while preparing the export; run :DoubtExport again", vim.log.levels.WARN)
			return
		end
		if not tree then
			if err == "Review-run diffs require a Git repository" then
				copy_export_payload(payload)
			else
				ctx.notify("Unable to prepare doubt export: " .. (err or "unknown error"), vim.log.levels.ERROR)
			end
			return
		end

		local completed_payload = build_export_payload(vim.tbl_extend("force", opts, {
			baseline_tree = tree,
			create_review_run = true,
			inspection = payload.inspection,
			skip_inspection_refresh = true,
			trusted_only = true,
		}))
		copy_export_payload(completed_payload)
	end)
end

local function copy_export_with_picker(copy)
	local template_names = M.list_export_templates()
	if vim.tbl_isempty(template_names) then
		ctx.notify("No doubt export templates configured", vim.log.levels.WARN)
		return
	end

	vim.ui.select(template_names, {
		prompt = "Choose doubt export template",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if not choice then
			return
		end

		copy({ template = choice })
	end)
end

function M.copy_export_with_picker()
	return copy_export_with_picker(M.copy_export)
end

function M.copy_export_with_picker_async()
	return copy_export_with_picker(M.copy_export_async)
end

function M.copy_filtered_export()
	local payload = build_export_payload({ template = "raw" })
	if not payload then
		return
	end

	local kinds = claims.list_claim_kinds()
	local counts = count_claim_kinds(payload.files)
	local items = {}
	for _, kind in ipairs(kinds) do
		table.insert(items, {
			label = string.format("%s (%d)", kind, counts[kind] or 0),
			value = kind,
		})
	end

	local input_config = config.get().input or {}
	input.ask_checklist({
		border = input_config.border,
		hint = "<Space> toggle  <CR> export  q cancel",
		items = items,
		title = "filtered export",
		width = math.max(input_config.width or 50, 34),
	}, function(selected_kinds, cancelled)
		if cancelled then
			return
		end

		if type(selected_kinds) ~= "table" or vim.tbl_isempty(selected_kinds) then
			ctx.notify("No claim types selected for filtered export", vim.log.levels.INFO)
			return
		end

		local filtered_files = export.filter_files_by_kind(payload.files, selected_kinds)
		local xml = export.build_session_xml(payload.session_name, filtered_files)
		local register = (config.get().export or {}).register or "+"
		vim.fn.setreg(register, xml)
		ctx.notify(string.format("Copied doubt export to %s (filtered raw)", register))
	end)
end

function M.copy_agent_instructions()
	local text = agent_instructions.render(config.get())
	local register = ((config.get().export or {}).register or "+")
	vim.fn.setreg(register, text)
	ctx.notify(string.format("Copied doubt agent instructions to %s", register))
	return text
end

function M.list_export_templates()
	return export.list_template_names(config.get().export)
end

function M.export_xml()
	local payload = build_export_payload({ template = "raw" })
	if not payload then
		return
	end

	vim.cmd("enew")
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.split(payload.xml, "\n", { plain = true })

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.bo[bufnr].filetype = "xml"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

function M.healthcheck()
	return healthcheck.run({
		notify = ctx.notify,
	})
end

function M.open_state_file()
	local current_config = config.get()
	state.save(current_config, ctx.notify)
	vim.cmd("edit " .. vim.fn.fnameescape(current_config.state_path))
end

function M.start_session(opts)
	inline_editor.close()
	opts = opts or {}

	local function activate(session_name)
		local already_exists = state.get().sessions[session_name] ~= nil
		state.set_active_session(session_name)
		refresh_active_session_claims()
		clear_expanded_claim()
		clear_focused_claim()
		state.save(config.get(), ctx.notify)
		ctx.refresh_ui()
		if not opts.quiet then
			local verb = already_exists and "Resumed" or "Started"
			ctx.notify(string.format("%s doubt session: %s", verb, session_name))
		end
	end

	if opts.name then
		local session_name = state.normalize_session_name(opts.name)
		if not session_name then
			ctx.notify("Session name cannot be empty", vim.log.levels.WARN)
			return
		end

		activate(session_name)
		return
	end

	prompt_session_name({
		prompt = "Start Doubt Session: ",
		title = "new doubt session",
	}, function(session_name, cancelled)
		if cancelled then
			return
		end

		activate(session_name)
	end)
end

function M.resume_session(opts)
	inline_editor.close()
	opts = opts or {}

	local function activate(session_name)
		state.set_active_session(session_name)
		refresh_active_session_claims()
		clear_expanded_claim()
		clear_focused_claim()
		state.save(config.get(), ctx.notify)
		ctx.refresh_ui()
		if not opts.quiet then
			ctx.notify(string.format("Resumed doubt session: %s", session_name))
		end
	end

	if opts.name then
		local session_name = state.normalize_session_name(opts.name)
		if not session_name or not state.get().sessions[session_name] then
			ctx.notify("Unknown doubt session", vim.log.levels.WARN)
			return
		end

		activate(session_name)
		return
	end

	local session_names = state.list_sessions()
	if vim.tbl_isempty(session_names) then
		ctx.notify("No saved doubt sessions yet", vim.log.levels.INFO)
		return
	end

	vim.ui.select(session_names, {
		prompt = "Resume doubt session",
		format_item = function(item)
			if item == state.active_session_name() then
				return item .. " (active)"
			end

			return item
		end,
	}, function(choice)
		if not choice then
			return
		end

		activate(choice)
	end)
end

function M.start_workspace_session(opts)
	inline_editor.close()
	opts = opts or {}

	local function activate(session_name)
		local already_exists = state.workspace_session_state(session_name) ~= nil
		if not state.set_active_workspace_session(session_name) then
			ctx.notify("Workspace session name cannot contain path separators", vim.log.levels.WARN)
			return
		end
		refresh_active_session_claims()
		clear_expanded_claim()
		clear_focused_claim()
		state.save(config.get(), ctx.notify)
		ctx.refresh_ui()
		if not opts.quiet then
			local verb = already_exists and "Resumed" or "Started"
			ctx.notify(string.format("%s doubt workspace session: %s", verb, session_name))
		end
	end

	if opts.name then
		local session_name = state.normalize_session_name(opts.name)
		if not session_name then
			ctx.notify("Session name cannot be empty", vim.log.levels.WARN)
			return
		end

		activate(session_name)
		return
	end

	prompt_session_name({
		prompt = "Start workspace session: ",
		title = "new doubt workspace session",
	}, function(session_name, cancelled)
		if cancelled then
			return
		end

		activate(session_name)
	end)
end

function M.resume_workspace_session(opts)
	inline_editor.close()
	opts = opts or {}

	local function activate(session_name)
		if not state.set_active_workspace_session(session_name) then
			ctx.notify("Unable to resume doubt workspace session", vim.log.levels.WARN)
			return
		end
		refresh_active_session_claims()
		clear_expanded_claim()
		clear_focused_claim()
		state.save(config.get(), ctx.notify)
		ctx.refresh_ui()
		if not opts.quiet then
			ctx.notify(string.format("Resumed doubt workspace session: %s", session_name))
		end
	end

	if opts.name then
		local session_name = state.normalize_session_name(opts.name)
		if not session_name or not state.workspace_session_state(session_name) then
			ctx.notify("Unknown doubt workspace session", vim.log.levels.WARN)
			return
		end

		activate(session_name)
		return
	end

	local session_names = state.list_workspace_sessions()
	if vim.tbl_isempty(session_names) then
		ctx.notify("No workspace doubt sessions yet", vim.log.levels.INFO)
		return
	end

	vim.ui.select(session_names, {
		prompt = "Resume doubt workspace session",
		format_item = function(item)
			if item == state.active_session_name() and state.active_session_source() == "workspace" then
				return item .. " (active)"
			end

			return item
		end,
	}, function(choice)
		if not choice then
			return
		end

		activate(choice)
	end)
end

function M.stop_session()
	inline_editor.close()
	local session_name = state.active_session_name()
	if not session_name then
		ctx.notify("No active doubt session", vim.log.levels.INFO)
		return
	end

	state.stop_session()
	clear_expanded_claim()
	clear_focused_claim()
	state.save(config.get(), ctx.notify)
	ctx.refresh_ui()
	ctx.notify(string.format("Stopped doubt session: %s", session_name))
end

local review_generation = 0

local function notify_review_started(review_context, session_name)
	if #review_context.files == 0 then
		ctx.notify(
			string.format("No changes between %s and the working tree", review_context.base_ref),
			vim.log.levels.INFO
		)
		return
	end
	ctx.notify(string.format(
		"Reviewing %s against %s: %d changed file%s (session %s)",
		review_context.branch,
		review_context.base_ref,
		#review_context.files,
		#review_context.files == 1 and "" or "s",
		session_name
	))
end

-- Local refs are enough to show the review immediately; network refresh happens in the background.
function M.start_review(opts)
	inline_editor.close()
	opts = opts or {}
	local review_config = config.get().review or {}
	local base = opts.base
	if base == nil or vim.trim(base) == "" then
		base = review_config.base
	end
	local fetch = review_config.fetch
	if opts.fetch ~= nil then
		fetch = opts.fetch
	end
	local viewer = opts.viewer or review_config.viewer
	local cwd = vim.fn.getcwd()
	local on_settled = opts.on_settled or function() end

	review_generation = review_generation + 1
	local generation = review_generation

	local function resolve_local()
		return pr_review.resolve({ base = base, cwd = cwd, fetch = false, gh = false })
	end

	local function activate(review_context)
		local session_name = pr_review.session_name(review_config.session_prefix, review_context.branch)
		M.start_session({ name = session_name, quiet = true })
		if state.active_session_name() ~= session_name then
			return nil
		end
		pr_review.set_context(session_name, review_context)
		if #review_context.files > 0 then
			review_context.viewer = pr_review.open_viewer(review_context, viewer)
		end
		notify_review_started(review_context, session_name)
		return session_name
	end

	local initial = resolve_local()
	local session_name = initial and activate(initial) or nil
	if initial and not session_name then
		on_settled(nil)
		return nil
	end
	if not fetch and review_config.gh == false then
		if not initial then
			ctx.notify(select(2, resolve_local()), vim.log.levels.WARN)
		end
		on_settled(initial)
		return initial
	end
	if not initial then
		ctx.notify("Fetching review base...", vim.log.levels.INFO)
	end

	pr_review.sync_remote({
		base = base and vim.trim(base) or nil,
		base_ref = initial and initial.base_ref or nil,
		cwd = cwd,
		fetch = fetch,
		gh = review_config.gh,
	}, function(remote)
		-- A newer :DoubtReview supersedes this one.
		if generation ~= review_generation then
			return
		end
		local updated, err = pr_review.resolve({ base = remote.base, cwd = cwd, fetch = false, gh = false })
		if not updated then
			ctx.notify(err, vim.log.levels.WARN)
			on_settled(initial)
			return
		end
		if remote.fetch_error and updated.base_ref == remote.target then
			ctx.notify(
				string.format("Could not fetch %s, reviewing local ref: %s", updated.base_ref, remote.fetch_error),
				vim.log.levels.WARN
			)
		end

		if not initial then
			if activate(updated) then
				on_settled(updated)
			else
				on_settled(nil)
			end
			return
		end

		if updated.base_ref == initial.base_ref and updated.merge_base == initial.merge_base then
			on_settled(initial)
			return
		end

		pr_review.set_context(session_name, updated)
		if pr_review.replace_viewer(initial, updated, viewer) then
			ctx.notify(string.format("Review base updated to %s", updated.base_ref))
		else
			ctx.notify(
				string.format("Review base updated to %s; rerun :DoubtReview to refresh the diff", updated.base_ref),
				vim.log.levels.WARN
			)
		end
		on_settled(updated)
	end)
	return initial
end

function M.delete_workspace_session(opts)
	opts = opts or {}

	local function destroy(session_name)
		local deleting_active = session_name == state.active_session_name() and state.active_session_source() == "workspace"
		if not confirm(string.format("Delete doubt workspace session '%s'?", session_name)) then
			return
		end
		if deleting_active then
			inline_editor.close()
		end

		if not state.delete_workspace_session(session_name) then
			ctx.notify("Unknown doubt workspace session", vim.log.levels.WARN)
			return
		end

		if deleting_active then
			clear_expanded_claim()
			clear_focused_claim()
		end

		ctx.refresh_ui()
		ctx.notify(string.format("Deleted doubt workspace session: %s", session_name))
	end

	if opts.name then
		local session_name = state.normalize_session_name(opts.name)
		if not session_name or not state.workspace_session_state(session_name) then
			ctx.notify("Unknown doubt workspace session", vim.log.levels.WARN)
			return
		end

		destroy(session_name)
		return
	end

	local session_names = state.list_workspace_sessions()
	if vim.tbl_isempty(session_names) then
		ctx.notify("No workspace doubt sessions yet", vim.log.levels.INFO)
		return
	end

	vim.ui.select(session_names, {
		prompt = "Delete doubt workspace session",
	}, function(choice)
		if choice then
			destroy(choice)
		end
	end)
end

function M.delete_session(opts)
	opts = opts or {}

	local function destroy(session_name)
		local deleting_active = session_name == state.active_session_name()
		if not confirm(string.format("Delete doubt session '%s'?", session_name)) then
			return
		end
		if deleting_active then
			inline_editor.close()
		end

		if not state.delete_session(session_name) then
			ctx.notify("Unknown doubt session", vim.log.levels.WARN)
			return
		end

		if deleting_active then
			clear_expanded_claim()
			clear_focused_claim()
		end

		state.save(config.get(), ctx.notify)
		ctx.refresh_ui()
		ctx.notify(string.format("Deleted doubt session: %s", session_name))
	end

	if opts.name then
		local session_name = state.normalize_session_name(opts.name)
		if not session_name or not state.get().sessions[session_name] then
			ctx.notify("Unknown doubt session", vim.log.levels.WARN)
			return
		end

		destroy(session_name)
		return
	end

	local session_names = state.list_sessions()
	if vim.tbl_isempty(session_names) then
		ctx.notify("No saved doubt sessions yet", vim.log.levels.INFO)
		return
	end

	vim.ui.select(session_names, {
		prompt = "Delete doubt session",
		format_item = function(item)
			if item == state.active_session_name() then
				return item .. " (active)"
			end

			return item
		end,
	}, function(choice)
		if not choice then
			return
		end

		destroy(choice)
	end)
end

function M.rename_session(opts)
	opts = opts or {}

	local function rename(old_name, new_name)
		if not state.rename_session(old_name, new_name) then
			ctx.notify("Unable to rename doubt session", vim.log.levels.WARN)
			return false
		end

		clear_expanded_claim()
		clear_focused_claim()
		state.save(config.get(), ctx.notify)
		ctx.refresh_ui()
		ctx.notify(string.format("Renamed doubt session: %s → %s", old_name, new_name))
		return true
	end

	local old_name = state.normalize_session_name(opts.name)
	if not old_name then
		ctx.notify("Session name cannot be empty", vim.log.levels.WARN)
		return false
	end

	if not state.get().sessions[old_name] then
		ctx.notify("Unknown doubt session", vim.log.levels.WARN)
		return false
	end

	local provided_new_name = state.normalize_session_name(opts.new_name)
	if opts.new_name ~= nil then
		if not provided_new_name then
			ctx.notify("Session name cannot be empty", vim.log.levels.WARN)
			return false
		end

		if provided_new_name == old_name then
			ctx.notify("Session name is unchanged", vim.log.levels.WARN)
			return false
		end

		if state.get().sessions[provided_new_name] then
			ctx.notify("Session name already exists", vim.log.levels.WARN)
			return false
		end

		return rename(old_name, provided_new_name)
	end

	prompt_session_name({
		default = old_name,
		prompt = "Rename session to: ",
		title = "rename doubt session",
	}, function(new_name, cancelled)
		if cancelled then
			return
		end

		if new_name == old_name then
			ctx.notify("Session name is unchanged", vim.log.levels.WARN)
			return
		end

		if state.get().sessions[new_name] then
			ctx.notify("Session name already exists", vim.log.levels.WARN)
			return
		end

		rename(old_name, new_name)
	end)

	return true
end

function M.rename_workspace_session(opts)
	opts = opts or {}

	local function rename(old_name, new_name)
		if not state.rename_workspace_session(old_name, new_name) then
			ctx.notify("Unable to rename doubt workspace session", vim.log.levels.WARN)
			return false
		end

		clear_expanded_claim()
		clear_focused_claim()
		ctx.refresh_ui()
		ctx.notify(string.format("Renamed doubt workspace session: %s → %s", old_name, new_name))
		return true
	end

	local old_name = state.normalize_session_name(opts.name)
	if not old_name then
		ctx.notify("Session name cannot be empty", vim.log.levels.WARN)
		return false
	end

	if not state.workspace_session_state(old_name) then
		ctx.notify("Unknown doubt workspace session", vim.log.levels.WARN)
		return false
	end

	local provided_new_name = state.normalize_session_name(opts.new_name)
	if opts.new_name ~= nil then
		if not provided_new_name then
			ctx.notify("Session name cannot be empty", vim.log.levels.WARN)
			return false
		end

		if provided_new_name == old_name then
			ctx.notify("Session name is unchanged", vim.log.levels.WARN)
			return false
		end

		if state.workspace_session_state(provided_new_name) then
			ctx.notify("Session name already exists", vim.log.levels.WARN)
			return false
		end

		return rename(old_name, provided_new_name)
	end

	prompt_session_name({
		default = old_name,
		prompt = "Rename workspace session to: ",
		title = "rename doubt workspace session",
	}, function(new_name, cancelled)
		if cancelled then
			return
		end

		if new_name == old_name then
			ctx.notify("Session name is unchanged", vim.log.levels.WARN)
			return
		end

		if state.workspace_session_state(new_name) then
			ctx.notify("Session name already exists", vim.log.levels.WARN)
			return
		end

		rename(old_name, new_name)
	end)

	return true
end

function M.setup(opts)
	stop_export_spinner(export_snapshot)
	export_snapshot_token = export_snapshot_token + 1
	inline_editor.close()
	ctx.api = M
	deleted_claim_stack = {}
	clear_live_edit_timers()
	config.setup(opts)
	config.set_highlights()
	claims.configure(config.get().claim_kinds)
	local workspace = ctx.normalize_path(vim.fn.getcwd())
	state.load(config.get(), ctx.normalize_path, ctx.notify, workspace)
	inline_editor.setup({
		config = config,
		ctx = ctx,
		input = input,
	})
	ctx.invalidate_review_run_inspection()
	ctx.set_inline_notes_layout(preferences.load(config.get(), ctx.notify).inline_notes_layout or "block")
	vim.api.nvim_clear_autocmds({ group = ctx.augroup })

	-- Decorations are derived from state, so entering a window is enough to restore them.
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = ctx.augroup,
		callback = function(args)
			render.refresh_buffer(ctx, args.buf)
		end,
	})

	-- Keep panel wrapping and virtual text layout in sync with window size changes.
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = ctx.augroup,
		callback = function()
			if not inline_editor.refresh() then
				ctx.refresh_ui()
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = ctx.augroup,
		callback = function(args)
			schedule_live_edit_refresh(args.buf)
		end,
	})

	-- Git baselines reflect files on disk, so update claim-diff status after writes rather than every keystroke.
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = ctx.augroup,
		callback = function()
			export_write_generation = export_write_generation + 1
			ctx.invalidate_review_run_inspection()
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = ctx.augroup,
		callback = function(args)
			stop_live_edit_timer(args.buf)
		end,
	})

	commands.register(M)
	keymaps.register(M, config.get().keymaps)
end

return M
