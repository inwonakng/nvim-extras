local Layout = require("markdown_table_renderer.layout")

local M = {}

local namespace = vim.api.nvim_create_namespace("markdown-table-renderer")

local function set_highlights()
	vim.api.nvim_set_hl(0, "MarkdownTableBorder", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "MarkdownTableHeader", { default = true, link = "@markup.heading" })
	vim.api.nvim_set_hl(0, "MarkdownTableCell", { default = true, link = "Normal" })
end

local function place(buf, parsed, lines, priority)
	local line_count = vim.api.nvim_buf_line_count(buf)
	if parsed.start_row < 0 or parsed.end_row > line_count or parsed.start_row >= parsed.end_row then
		return false
	end

	local anchor
	if parsed.start_row > 0 then
		anchor = { row = parsed.start_row - 1, above = false }
	else
		-- A one-past-EOF extmark remains a visible virtual-line anchor when the
		-- table occupies the entire buffer. `strict = false` permits that row.
		anchor = { row = parsed.end_row, above = true }
	end

	for row = parsed.start_row, parsed.end_row - 1 do
		vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
			conceal_lines = "",
			invalidate = true,
			priority = priority,
			strict = false,
			undo_restore = false,
		})
	end
	vim.api.nvim_buf_set_extmark(buf, namespace, anchor.row, 0, {
		virt_lines = lines,
		virt_lines_above = anchor.above,
		invalidate = true,
		priority = priority,
		strict = false,
		undo_restore = false,
	})
	return true
end

function M.apply(buf, tables, config, win, focused)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	set_highlights()
	local rendered = 0
	for _, parsed in ipairs(tables) do
		if not focused(parsed) then
			local lines = Layout.render(parsed, config, win)
			if place(buf, parsed, lines, config.priority) then
				rendered = rendered + 1
			end
		end
	end
	return rendered
end

function M.clear(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	end
end

function M.namespace()
	return namespace
end

function M.set_highlights()
	set_highlights()
end

return M
