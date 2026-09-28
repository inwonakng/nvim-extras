local Compiler = require("latex_renderer.compiler")
local DisplayFences = require("latex_renderer.display_fences")
local Inline = require("latex_renderer.inline")
local Kitty = require("latex_renderer.kitty")
local Utftex = require("latex_renderer.utftex")

local M = {}

local display_ns = vim.api.nvim_create_namespace("latex-renderer-display")
local states = {}
local did_setup = false
local latex_query
local markdown_protected_query
local markdown_inline_protected_query
local config = {
	debounce_ms = 30,
	max_width = 80,
	max_height = 30,
	prefetch_lines = 30,
	scale = 0.8,
}

local function valid_buf(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function sync_tmux_depth()
	if not vim.env.TMUX or not vim.env.TMUX_PANE or vim.fn.executable("tmux") ~= 1 then
		return
	end
	local result = vim.system({
		"tmux",
		"show-options",
		"-qv",
		"-t",
		vim.env.TMUX_PANE,
		"@graphics-nest-count",
	}, { text = true }):wait()
	local depth = vim.trim(result.stdout or "")
	if result.code == 0 and tonumber(depth) then
		vim.env.TMUX_NEST_COUNT = depth
	end
end

local function math_color()
	for _, name in ipairs({ "@markup.math", "Special", "Normal" }) do
		local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
		if ok and highlight.fg then
			return ("%06X"):format(highlight.fg)
		end
	end
	return "FFFFFF"
end

local function compare_position(row, col, other_row, other_col)
	return row < other_row or (row == other_row and col < other_col)
end

local function contains(outer, inner)
	local starts_before = not compare_position(inner.start_row, inner.start_col, outer.start_row, outer.start_col)
	local ends_after = not compare_position(outer.end_row, outer.end_col, inner.end_row, inner.end_col)
	return starts_before and ends_after
end

local function contains_position(item, row, col)
	local after_start = not compare_position(row, col, item.start_row, item.start_col)
	local before_end = compare_position(row, col, item.end_row, item.end_col)
	return after_start and before_end
end

local function overlaps(left, right)
	local left_before_right_end = compare_position(left.start_row, left.start_col, right.end_row, right.end_col)
	local right_before_left_end = compare_position(right.start_row, right.start_col, left.end_row, left.end_col)
	return left_before_right_end and right_before_left_end
end

local function sort_items(items)
	table.sort(items, function(left, right)
		if left.start_row ~= right.start_row then
			return left.start_row < right.start_row
		end
		if left.start_col ~= right.start_col then
			return left.start_col < right.start_col
		end
		if left.end_row ~= right.end_row then
			return left.end_row > right.end_row
		end
		return left.end_col > right.end_col
	end)
end

local function remove_nested(items)
	sort_items(items)
	local filtered = {}
	for _, item in ipairs(items) do
		local nested = false
		for _, outer in ipairs(filtered) do
			if contains(outer, item) then
				nested = true
				break
			end
		end
		if not nested then
			filtered[#filtered + 1] = item
		end
	end
	return filtered
end

local function node_range(node)
	local start_row, start_col, end_row, end_col = node:range()
	return {
		start_row = start_row,
		start_col = start_col,
		end_row = end_row,
		end_col = end_col,
	}
end

local function overlaps_any(item, ranges)
	for _, range in ipairs(ranges) do
		if overlaps(item, range) then
			return true
		end
	end
	return false
end

local function scan(buf)
	if not latex_query then
		latex_query = vim.treesitter.query.parse("latex", [[
			(inline_formula) @inline
			(displayed_equation) @display
			(math_environment) @display
		]])
		markdown_protected_query = vim.treesitter.query.parse("markdown", [[
			(fenced_code_block) @protected
			(indented_code_block) @protected
		]])
		markdown_inline_protected_query = vim.treesitter.query.parse("markdown_inline", [[
			(code_span) @protected
		]])
	end

	local parser = vim.treesitter.get_parser(buf, "markdown")
	parser:parse(true)
	local display = {}
	local inline = {}
	local protected = {}
	parser:for_each_tree(function(tree, language_tree)
		local language = language_tree:lang()
		local query
		if language == "markdown" then
			query = markdown_protected_query
		elseif language == "markdown_inline" then
			query = markdown_inline_protected_query
		end
		if query then
			for _, node in query:iter_captures(tree:root(), buf) do
				protected[#protected + 1] = node_range(node)
			end
		end

		local parent = language_tree:parent()
		if language ~= "latex" or not parent or parent:lang() ~= "markdown_inline" then
			return
		end
		for capture_id, node in latex_query:iter_captures(tree:root(), buf) do
			local item = node_range(node)
			item.text = vim.treesitter.get_node_text(node, buf)
			local capture = latex_query.captures[capture_id]
			if capture == "display" then
				display[#display + 1] = item
			elseif capture == "inline" then
				inline[#inline + 1] = item
			end
		end
	end)

	local fenced_display = DisplayFences.scan(vim.api.nvim_buf_get_lines(buf, 0, -1, false), function(row, col)
		for _, range in ipairs(protected) do
			if contains_position(range, row, col) then
				return true
			end
		end
		return false
	end)

	local merged_display = {}
	for _, item in ipairs(display) do
		if not overlaps_any(item, fenced_display) then
			merged_display[#merged_display + 1] = item
		end
	end
	vim.list_extend(merged_display, fenced_display)

	local retained_inline = {}
	for _, item in ipairs(inline) do
		if not overlaps_any(item, fenced_display) then
			retained_inline[#retained_inline + 1] = item
		end
	end

	sort_items(retained_inline)
	return remove_nested(merged_display), retained_inline
end

local function normalize_display_source(source)
	source = vim.trim(source)
	if vim.startswith(source, "$$") and vim.endswith(source, "$$") then
		return "\\[\n" .. vim.trim(source:sub(3, -3)) .. "\n\\]"
	end
	return source
end

local function normalize_inline_source(source)
	source = vim.trim(source)
	if vim.startswith(source, "$") and vim.endswith(source, "$") then
		return source:sub(2, -2)
	end
	return source
end

local function display_key(item)
	return table.concat({ item.start_row, item.start_col, item.end_row, item.end_col }, ":")
end

local function item_focused(buf, item)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			local cursor = vim.api.nvim_win_get_cursor(win)
			local row, col = cursor[1] - 1, cursor[2]
			local after_start = not compare_position(row, col, item.start_row, item.start_col)
			local before_end = compare_position(row, col, item.end_row, item.end_col)
			if after_start and before_end then
				return true
			end
		end
	end
	return false
end

local function item_on_cursor_line(buf, item)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			local row = vim.api.nvim_win_get_cursor(win)[1] - 1
			if row >= item.start_row and row <= item.end_row then
				return true
			end
		end
	end
	return false
end

local function item_visible(buf, item)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			local viewport = vim.api.nvim_win_call(win, function()
				return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
			end)
			local top = math.max(0, viewport[1] - config.prefetch_lines)
			local bottom = viewport[2] + config.prefetch_lines
			if item.end_row >= top and item.start_row <= bottom then
				return true
			end
		end
	end
	return false
end

local function display_width(buf)
	local width
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			width = math.max(width or 1, vim.api.nvim_win_get_width(win))
			if win == vim.api.nvim_get_current_win() then
				return vim.api.nvim_win_get_width(win)
			end
		end
	end
	return width or vim.o.columns
end

function M.fit(width_px, height_px, max_width, max_height, cell_width, cell_height, scale)
	scale = scale or 1
	assert(type(scale) == "number" and scale > 0, "latex renderer scale must be a positive number")
	local natural_width = math.max(1, math.ceil(width_px / cell_width)) * scale
	local natural_height = math.max(1, math.ceil(height_px / cell_height)) * scale
	local fit_scale = math.min(1, max_width / natural_width, max_height / natural_height)
	return math.max(1, math.floor(natural_width * fit_scale + 0.5)),
		math.max(1, math.floor(natural_height * fit_scale + 0.5))
end

local function clear_mark(buf, entry)
	if valid_buf(buf) then
		if entry.conceal_mark then
			pcall(vim.api.nvim_buf_del_extmark, buf, display_ns, entry.conceal_mark)
		end
		if entry.image_mark then
			pcall(vim.api.nvim_buf_del_extmark, buf, display_ns, entry.image_mark)
		end
	end
	entry.conceal_mark = nil
	entry.image_mark = nil
end

local function clear_entry(buf, entry)
	clear_mark(buf, entry)
	if entry.cancel then
		entry.cancel()
		entry.cancel = nil
	end
	if entry.image_id then
		Kitty.delete(entry.image_id)
	end
end

local function send_entry(entry, force)
	local layout = table.concat({ Kitty.tmux_depth(), entry.width, entry.height }, ":")
	if not force and entry.sent_layout == layout then
		return
	end
	if entry.sent_layout then
		Kitty.delete(entry.image_id)
	end
	Kitty.transmit(entry.meta.path, entry.image_id)
	Kitty.place(entry.image_id, entry.width, entry.height)
	entry.sent_layout = layout
end

local function apply_entry(buf, entry, force_send)
	clear_mark(buf, entry)
	if item_focused(buf, entry.item) then
		return
	end

	local cell_width, cell_height = Kitty.cell_size()
	local window_width = display_width(buf)
	local max_width = math.max(1, math.min(config.max_width, window_width - 2))
	entry.width, entry.height = M.fit(
		entry.meta.width_px,
		entry.meta.height_px,
		max_width,
		config.max_height,
		cell_width,
		cell_height,
		config.scale
	)
	send_entry(entry, force_send)
	local padding = math.max(0, math.floor((window_width - entry.width) / 2))
	local lines = Kitty.placeholder_lines(entry.width, entry.height, entry.image_id, padding)
	entry.conceal_mark = vim.api.nvim_buf_set_extmark(buf, display_ns, entry.item.start_row, entry.item.start_col, {
		end_row = entry.item.end_row,
		end_col = entry.item.end_col,
		conceal_lines = "",
		priority = 250,
		strict = false,
	})
	local anchor = entry.item.end_row + (entry.item.end_col > 0 and 1 or 0)
	anchor = math.min(anchor, vim.api.nvim_buf_line_count(buf))
	entry.image_mark = vim.api.nvim_buf_set_extmark(buf, display_ns, anchor, 0, {
		virt_lines = lines,
		virt_lines_above = true,
		priority = 250,
		strict = false,
	})
end

local function clear_inline_entry(entry)
	if entry.cancel then
		entry.cancel()
		entry.cancel = nil
	end
end

local inline_error_notifications = {}

local function notify_compile_error(err)
	vim.notify("Could not render LaTeX: " .. err, vim.log.levels.WARN, {
		title = "latex-renderer",
	})
end

local function notify_inline_error(source, err)
	local notification_key = source .. "\0" .. err
	if inline_error_notifications[notification_key] then
		return
	end
	inline_error_notifications[notification_key] = true
	local preview = source:gsub("%s+", " ")
	if #preview > 120 then
		preview = preview:sub(1, 117) .. "..."
	end
	vim.notify(("Could not render inline LaTeX: %s\nFormula: %s"):format(err, preview), vim.log.levels.WARN, {
		title = "latex-renderer",
	})
end

local function render(buf)
	local state = states[buf]
	if not state or not valid_buf(buf) then
		return
	end

	local ok, display_items, inline_items = pcall(scan, buf)
	if not ok then
		if state.scan_error ~= display_items then
			state.scan_error = display_items
			vim.notify("Could not parse Markdown equations: " .. tostring(display_items), vim.log.levels.WARN, {
				title = "latex-renderer",
			})
		end
		return
	end
	state.scan_error = nil

	local active_displays = {}
	local color = math_color()
	for _, item in ipairs(display_items) do
		local key = display_key(item)
		active_displays[key] = true
		local source = normalize_display_source(item.text)
		local entry = state.displays[key]
		if entry and (entry.source ~= source or entry.color ~= color) then
			clear_entry(buf, entry)
			state.displays[key] = nil
			entry = nil
		end
		if not entry then
			entry = {
				item = item,
				source = source,
				color = color,
			}
			state.displays[key] = entry
		else
			entry.item = item
		end

		if entry.meta then
			apply_entry(buf, entry, false)
		elseif item_visible(buf, item) and not entry.pending and not entry.failed then
			entry.pending = true
			local expected = entry
			entry.cancel = Compiler.compile(source, color, function(meta, err)
				local current = states[buf]
				if not current or current.displays[key] ~= expected or not valid_buf(buf) then
					return
				end
				expected.pending = nil
				expected.cancel = nil
				if not meta then
					expected.failed = true
					notify_compile_error(err or "unknown compiler error")
					return
				end
				expected.meta = meta
				expected.image_id = Kitty.next_id()
				apply_entry(buf, expected, true)
			end)
		end
	end

	for key, entry in pairs(state.displays) do
		if not active_displays[key] then
			clear_entry(buf, entry)
			state.displays[key] = nil
		end
	end

	local active_inlines = {}
	for _, item in ipairs(inline_items) do
		local key = display_key(item)
		active_inlines[key] = true
		local source = normalize_inline_source(item.text)
		local entry = state.inlines[key]
		if entry and entry.source ~= source then
			clear_inline_entry(entry)
			state.inlines[key] = nil
			entry = nil
		end
		if not entry then
			entry = {
				item = item,
				source = source,
			}
			state.inlines[key] = entry
		else
			entry.item = item
		end

		if not entry.output and item_visible(buf, item) and not entry.pending and not entry.failed then
			entry.pending = true
			local expected = entry
			entry.cancel = Utftex.convert(source, function(result, err)
				local current = states[buf]
				if not current or current.inlines[key] ~= expected or not valid_buf(buf) then
					return
				end
				expected.pending = nil
				expected.cancel = nil
				if not result then
					expected.failed = true
					notify_inline_error(source, err or "unknown converter error")
					return
				end
				expected.output = result.output
				expected.baseline = result.baseline
				Inline.apply(buf, current.inlines, function(item)
					return item_on_cursor_line(buf, item)
				end)
			end)
		end
	end

	for key, entry in pairs(state.inlines) do
		if not active_inlines[key] then
			clear_inline_entry(entry)
			state.inlines[key] = nil
		end
	end
	Inline.apply(buf, state.inlines, function(item)
		return item_on_cursor_line(buf, item)
	end)
end

function M.queue(buf, immediate)
	if not valid_buf(buf) then
		return
	end
	if not states[buf] then
		M.attach(buf)
	end
	local state = states[buf]
	if not state then
		return
	end

	if state.queued then
		if not immediate or state.queued == "immediate" then
			return
		end
	end

	state.queue_generation = (state.queue_generation or 0) + 1
	local generation = state.queue_generation
	state.queued = immediate and "immediate" or "deferred"
	local function run()
		if states[buf] == state and state.queue_generation == generation then
			state.queued = nil
			render(buf)
		end
	end
	if immediate then
		vim.schedule(run)
	else
		vim.defer_fn(run, config.debounce_ms)
	end
end

function M.attach(buf)
	if not valid_buf(buf) or states[buf] then
		return
	end
	pcall(vim.treesitter.start, buf, "markdown")
	states[buf] = { displays = {}, inlines = {} }
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			vim.schedule(function()
				if states[buf] then
					M.queue(buf)
				end
			end)
		end,
		on_detach = function()
			local state = states[buf]
			if state then
				for _, entry in pairs(state.displays) do
					if entry.cancel then
						entry.cancel()
					end
					if entry.image_id then
						Kitty.delete(entry.image_id)
					end
				end
				for _, entry in pairs(state.inlines) do
					clear_inline_entry(entry)
				end
			end
			states[buf] = nil
		end,
	})
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
		end
	end
	M.queue(buf, true)
end

function M.detach(buf)
	local state = states[buf]
	if not state then
		return
	end
	for _, entry in pairs(state.displays) do
		clear_entry(buf, entry)
	end
	for _, entry in pairs(state.inlines) do
		clear_inline_entry(entry)
	end
	if valid_buf(buf) then
		vim.api.nvim_buf_clear_namespace(buf, display_ns, 0, -1)
		Inline.clear(buf)
	end
	states[buf] = nil
end

local function queue_visible_markdown()
	local seen = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if not seen[buf] and vim.bo[buf].filetype == "markdown" then
			seen[buf] = true
			M.queue(buf)
		end
	end
end

function M.setup(opts)
	if did_setup then
		return
	end
	local next_config = vim.tbl_extend("force", config, opts or {})
	assert(
		type(next_config.scale) == "number" and next_config.scale > 0,
		"latex renderer scale must be a positive number"
	)
	config = next_config
	did_setup = true
	sync_tmux_depth()

	local group = vim.api.nvim_create_augroup("latex-renderer", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "markdown",
		callback = function(args)
			M.attach(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = group,
		callback = function(args)
			if vim.bo[args.buf].filetype == "markdown" then
				M.attach(args.buf)
				local win = vim.api.nvim_get_current_win()
				if vim.api.nvim_win_get_buf(win) == args.buf then
					vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
				end
				M.queue(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		callback = function(args)
			if states[args.buf] then
				M.queue(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group,
		callback = queue_visible_markdown,
	})
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = queue_visible_markdown,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			Kitty.invalidate_cell_size()
			queue_visible_markdown()
		end,
	})
	vim.api.nvim_create_autocmd("FocusGained", {
		group = group,
		callback = function()
			sync_tmux_depth()
			for buf, state in pairs(states) do
				for _, entry in pairs(state.displays) do
					if entry.meta then
						apply_entry(buf, entry, true)
					end
				end
				M.queue(buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			M.detach(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			local buffers = vim.tbl_keys(states)
			for _, buf in ipairs(buffers) do
				M.detach(buf)
			end
		end,
	})
	vim.api.nvim_create_user_command("LatexRendererRefresh", function()
		local buf = vim.api.nvim_get_current_buf()
		local state = states[buf]
		if state then
			for _, entry in pairs(state.displays) do
				entry.failed = nil
				if entry.sent_layout then
					Kitty.delete(entry.image_id)
					entry.sent_layout = nil
				end
			end
			for _, entry in pairs(state.inlines) do
				entry.failed = nil
			end
		end
		inline_error_notifications = {}
		M.queue(buf, true)
	end, {})

	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buf].filetype == "markdown" then
			M.attach(buf)
		end
	end
end

M.scan = scan
M.sync_tmux_depth = sync_tmux_depth

return M
