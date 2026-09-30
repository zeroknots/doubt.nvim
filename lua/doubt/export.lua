-- Pure XML formatter for active-session handoff data.
local claims = require("doubt.claims")
local config = require("doubt.config")
local M = {}

local function xml_escape(value)
	value = tostring(value or "")
	value = value:gsub("&", "&amp;")
	value = value:gsub("<", "&lt;")
	value = value:gsub(">", "&gt;")
	value = value:gsub('"', "&quot;")
	value = value:gsub("'", "&apos;")
	return value
end

local function xml_line(claim, review_run)
	local id_line = ""
	if type(claim.id) == "string" and claim.id ~= "" then
		id_line = string.format('    id="%s"\n', xml_escape(claim.id))
	end
	return string.format(
		'  <claim\n%s    kind="%s"\n    start_line="%d"\n    start_col="%d"\n    end_line="%d"\n    end_col="%d"\n    note="%s"\n  />',
		id_line,
		xml_escape(claim.kind),
		math.max(tonumber(claim.start_line) or 0, 0) + 1,
		math.max(tonumber(claim.start_col) or 0, 0),
		math.max(tonumber(claim.end_line) or 0, 0) + 1,
		math.max(tonumber(claim.end_col) or 0, 0),
		xml_escape(claim.note)
	)
end

local function count_claims(files)
	local total = 0

	for _, file_state in pairs(files or {}) do
		total = total + #((file_state or {}).claims or {})
	end

	return total
end

local function resolve_export_config(export_config)
	local current = vim.deepcopy(((config.get() or {}).export) or {})
	if type(export_config) ~= "table" then
		return current
	end

	return vim.tbl_deep_extend("force", current, export_config)
end

local function instruction_text_for_kind(kind, export_config)
	export_config = resolve_export_config(export_config)
	local instructions = type(export_config.instructions) == "table" and export_config.instructions or {}
	local normalized_kind = claims.normalize_claim_kind(kind)
	local instruction = instructions[normalized_kind]
	if type(instruction) == "string" and vim.trim(instruction) ~= "" then
		return vim.trim(instruction)
	end

	return string.format("Address the %s claim according to the reviewer feedback.", normalized_kind)
end

local function collect_export_instructions(files, export_config)
	local paths = vim.tbl_keys(files or {})
	table.sort(paths)

	local kinds_seen = {}
	local ordered_instructions = {}

	for _, path in ipairs(paths) do
		for _, claim in ipairs((files[path] or {}).claims or {}) do
			local kind = claims.normalize_claim_kind(claim.kind)
			if not kinds_seen[kind] then
				kinds_seen[kind] = true
				table.insert(ordered_instructions, {
					kind = kind,
					text = instruction_text_for_kind(kind, export_config),
				})
			end
		end
	end

	return ordered_instructions
end

local function append_instruction_block(lines, files, export_config)
	local instructions = collect_export_instructions(files, export_config)
	if vim.tbl_isempty(instructions) then
		return
	end

	table.insert(lines, "  <instructions>")
	for _, instruction in ipairs(instructions) do
		table.insert(lines, string.format(
			'    <instruction kind="%s">%s</instruction>',
			xml_escape(instruction.kind),
			xml_escape(instruction.text)
		))
	end
	table.insert(lines, "  </instructions>")
end

function M.select_trusted_files(files, review_statuses)
	files = type(files) == "table" and files or {}
	review_statuses = type(review_statuses) == "table" and review_statuses or {}

	local filtered = {}
	local exportable_claim_count = 0
	local skipped_reviewed_claims = 0
	local skipped_stale_claims = 0

	for path, file_state in pairs(files) do
		local trusted_claims = {}
		for _, claim in ipairs((file_state or {}).claims or {}) do
			local normalized = claims.normalize_claim(claim)
			if normalized and (normalized.freshness == "fresh" or normalized.freshness == "reanchored") then
				local status = review_statuses[normalized.id]
				local reviewed_revision = status and status.claim_revision or nil
				local unchanged_reviewed_claim = reviewed_revision ~= nil
					and reviewed_revision == claims.review_revision(normalized)
				if unchanged_reviewed_claim then
					skipped_reviewed_claims = skipped_reviewed_claims + 1
				else
					table.insert(trusted_claims, normalized)
					exportable_claim_count = exportable_claim_count + 1
				end
			else
				skipped_stale_claims = skipped_stale_claims + 1
			end
		end

		if not vim.tbl_isempty(trusted_claims) then
			filtered[path] = { claims = trusted_claims }
		end
	end

	return filtered, {
		exportable_claim_count = exportable_claim_count,
		exportable_file_count = vim.tbl_count(filtered),
		skipped_reviewed_claims = skipped_reviewed_claims,
		skipped_stale_claims = skipped_stale_claims,
	}
end

local function render_template(template, payload)
	return (template:gsub("{{%s*([%w_]+)%s*}}", function(key)
		local value = payload[key]
		if value == nil then
			return ""
		end

		return tostring(value)
	end))
end

function M.list_template_names(export_config)
	export_config = type(export_config) == "table" and export_config or {}
	local templates = type(export_config.templates) == "table" and export_config.templates or {}
	local names = {}

	for name, template in pairs(templates) do
		if type(name) == "string" and name ~= "" and type(template) == "string" and template ~= "" then
			table.insert(names, name)
		end
	end

	table.sort(names)
	return names
end

function M.build_session_xml(session_name, files, export_config, review_run)
	if type(session_name) ~= "string" or vim.trim(session_name) == "" then
		return nil
	end

	files = type(files) == "table" and files or {}
	export_config = resolve_export_config(export_config)
	if vim.tbl_isempty(files) and not review_run then
		return string.format('<doubt session="%s"></doubt>', xml_escape(session_name))
	end

	local root_line = string.format('<doubt session="%s">', xml_escape(session_name))
	if review_run then
		root_line = string.format(
			'<doubt session="%s" run_id="%s" manifest_path="%s">',
			xml_escape(session_name),
			xml_escape(review_run.run_id),
			xml_escape(review_run.manifest_path)
		)
	end
	local lines = {
		root_line,
	}
	local paths = vim.tbl_keys(files)
	table.sort(paths)
	append_instruction_block(lines, files, export_config)

	for _, path in ipairs(paths) do
		table.insert(lines, string.format('  <file path="%s">', xml_escape(path)))

		for _, claim in ipairs((files[path] or {}).claims or {}) do
			table.insert(lines, xml_line(claim, review_run))
		end

		table.insert(lines, "  </file>")
	end

	table.insert(lines, "</doubt>")
	return table.concat(lines, "\n")
end

function M.filter_files_by_kind(files, included_kinds)
	files = type(files) == "table" and files or {}
	included_kinds = type(included_kinds) == "table" and included_kinds or {}

	local included = {}
	for _, kind in ipairs(included_kinds) do
		included[claims.normalize_claim_kind(kind)] = true
	end

	local filtered = {}
	for path, file_state in pairs(files) do
		local filtered_claims = {}
		for _, claim in ipairs((file_state or {}).claims or {}) do
			if included[claims.normalize_claim_kind(claim.kind)] then
				table.insert(filtered_claims, vim.deepcopy(claim))
			end
		end

		if not vim.tbl_isempty(filtered_claims) then
			filtered[path] = { claims = filtered_claims }
		end
	end

	return filtered
end

function M.build_export_text(opts)
	opts = opts or {}
	local export_config = resolve_export_config(opts.export_config)
	local template_name = opts.template or export_config.default_template or "raw"
	local templates = type(export_config.templates) == "table" and export_config.templates or {}
	local template = templates[template_name]

	if type(template) ~= "string" or template == "" then
		return nil, string.format("Unknown doubt export template: %s", template_name)
	end

	local xml = opts.xml or M.build_session_xml(opts.session_name, opts.files, export_config, opts.review_run)
	if not xml then
		return nil, "Unable to export doubt session"
	end

	local files = type(opts.files) == "table" and opts.files or {}
	local payload = {
		claim_count = count_claims(files),
		file_count = vim.tbl_count(files),
		manifest_path = opts.review_run and opts.review_run.manifest_path or "",
		review_context = opts.review_context or "",
		run_id = opts.review_run and opts.review_run.run_id or "",
		session = opts.session_name,
		session_name = opts.session_name,
		xml = xml,
	}

	local text = render_template(template, payload)
	if opts.review_run and type(opts.review_run.protocol_text) == "string" and opts.review_run.protocol_text ~= "" then
		text = text .. "\n\n" .. opts.review_run.protocol_text
	end
	return text, nil, template_name
end

return M
