local Inline = require("markdown_table_renderer.inline")
local Parser = require("markdown_table_renderer.parser")
local Renderer = require("markdown_table_renderer.renderer")

local M = {}

local states = {}
local did_setup = false
local notified_errors = {}
local config = {
	debounce_ms = 40,
	max_width_ratio = 0.95,
	min_col_width = 6,
	max_col_width = 40,
	priority = 250,
	row_separator = true,
}

local function valid_buffer(buf)
	return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function window_for(buf)
	local current = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == buf then
		return current
	end
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			return win
		end
	end
	return nil
end

local function active_window_for(buf)
	local win = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
		return win
	end
	return nil
end

local function table_at_cursor(tables, win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(win)[1] - 1
	for _, parsed in ipairs(tables or {}) do
		if row >= parsed.start_row and row < parsed.end_row then
			return parsed
		end
	end
	return nil
end

local function table_focused(buf, parsed)
	return table_at_cursor({ parsed }, active_window_for(buf)) ~= nil
end

local function focus_signature(buf, tables)
	local parsed = table_at_cursor(tables, active_window_for(buf))
	return parsed and parsed.id or ""
end

local function ensure_conceallevel(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) and vim.wo[win].conceallevel < 2 then
			vim.wo[win].conceallevel = 2
		end
	end
end

local function notify_once(message)
	if notified_errors[message] then
		return
	end
	notified_errors[message] = true
	vim.notify("Could not render Markdown tables: " .. message, vim.log.levels.WARN, {
		title = "markdown-table-renderer",
	})
end

local function render(buf)
	local state = states[buf]
	if not state or not valid_buffer(buf) then
		return
	end
	local win = window_for(buf)
	if not win then
		Renderer.clear(buf)
		return
	end

	local ok, tables = pcall(Parser.scan, buf)
	if not ok then
		Renderer.clear(buf)
		state.tables = {}
		notify_once(tostring(tables))
		return
	end
	state.tables = tables
	state.focus_signature = focus_signature(buf, tables)
	local rendered = Renderer.apply(buf, tables, config, win, function(parsed)
		return table_focused(buf, parsed)
	end)
	if rendered > 0 then
		ensure_conceallevel(buf)
	end
end

function M.queue(buf, immediate)
	local state = states[buf]
	if not state or not valid_buffer(buf) then
		return
	end
	state.generation = (state.generation or 0) + 1
	local generation = state.generation
	local function run()
		if states[buf] == state and state.generation == generation then
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
	if not valid_buffer(buf) or states[buf] or vim.bo[buf].filetype ~= "markdown" then
		return
	end
	local state = { tables = {}, focus_signature = "" }
	states[buf] = state
	pcall(vim.treesitter.start, buf, "markdown")
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			if states[buf] ~= state then
				return true
			end
			vim.schedule(function()
				M.queue(buf, false)
			end)
		end,
		on_detach = function()
			if states[buf] == state then
				states[buf] = nil
			end
		end,
	})
	M.queue(buf, true)
end

function M.detach(buf)
	Renderer.clear(buf)
	states[buf] = nil
end

local function queue_visible_markdown(immediate)
	local seen = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if not seen[buf] and vim.bo[buf].filetype == "markdown" then
			seen[buf] = true
			M.attach(buf)
			M.queue(buf, immediate)
		end
	end
end

function M.setup(opts)
	if did_setup then
		return
	end
	assert(vim.fn.has("nvim-0.11") == 1, "markdown table renderer requires Neovim 0.11+")
	local next_config = vim.tbl_extend("force", config, opts or {})
	assert(type(next_config.debounce_ms) == "number" and next_config.debounce_ms >= 0, "invalid debounce_ms")
	assert(
		type(next_config.max_width_ratio) == "number"
			and next_config.max_width_ratio > 0
			and next_config.max_width_ratio <= 1,
		"invalid max_width_ratio"
	)
	assert(type(next_config.min_col_width) == "number" and next_config.min_col_width >= 1, "invalid min_col_width")
	assert(
		type(next_config.max_col_width) == "number" and next_config.max_col_width >= next_config.min_col_width,
		"invalid max_col_width"
	)
	config = next_config
	did_setup = true
	Renderer.set_highlights()

	local group = vim.api.nvim_create_augroup("markdown-table-renderer", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "*",
		callback = function(args)
			if vim.bo[args.buf].filetype == "markdown" then
				M.attach(args.buf)
			elseif states[args.buf] then
				M.detach(args.buf)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = group,
		callback = function(args)
			if vim.bo[args.buf].filetype == "markdown" then
				M.attach(args.buf)
				M.queue(args.buf, true)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = function(args)
			if states[args.buf] then
				M.queue(args.buf, true)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = group,
		callback = function(args)
			local state = states[args.buf]
			if state then
				local signature = focus_signature(args.buf, state.tables)
				if signature ~= state.focus_signature then
					M.queue(args.buf, true)
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("ModeChanged", {
		group = group,
		callback = function(args)
			if states[args.buf] then
				M.queue(args.buf, true)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = group,
		callback = function()
			queue_visible_markdown(false)
		end,
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = {
			"conceallevel",
			"number",
			"relativenumber",
			"numberwidth",
			"signcolumn",
			"foldcolumn",
			"statuscolumn",
		},
		callback = function(args)
			local buf = vim.api.nvim_get_current_buf()
			if states[buf] then
				M.queue(buf, args.match == "conceallevel")
			end
		end,
	})
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			Renderer.set_highlights()
			Inline.clear_cache()
			queue_visible_markdown(true)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			M.detach(args.buf)
		end,
	})
	vim.api.nvim_create_user_command("MarkdownTableRendererRefresh", function()
		Inline.clear_cache()
		local buf = vim.api.nvim_get_current_buf()
		M.attach(buf)
		M.queue(buf, true)
	end, {})

	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		M.attach(buf)
	end
end

M.scan = Parser.scan
M.namespace = Renderer.namespace

return M
