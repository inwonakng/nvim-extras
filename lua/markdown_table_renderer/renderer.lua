local Layout = require("markdown_table_renderer.layout")

local M = {}

local namespace = vim.api.nvim_create_namespace("markdown-table-renderer")

local function set_highlights()
	vim.api.nvim_set_hl(0, "MarkdownTableBorder", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "MarkdownTableHeader", { default = true, link = "@markup.heading" })
	vim.api.nvim_set_hl(0, "MarkdownTableCell", { default = true, link = "Normal" })
end

local function place(buf, block, priority)
	local source = vim.api.nvim_buf_get_lines(buf, block.source_row, block.source_row + 1, false)[1]
	if not source then
		return false
	end

	-- Conceal text, not the buffer line: normal motions must still reach each row.
	vim.api.nvim_buf_set_extmark(buf, namespace, block.source_row, 0, {
		end_col = #source,
		conceal = "",
		virt_text = block.lines[1],
		virt_text_pos = "overlay",
		virt_lines = vim.list_slice(block.lines, 2),
		invalidate = true,
		priority = priority,
		undo_restore = false,
	})
	return true
end

function M.apply(buf, tables, config, win, focused)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	set_highlights()
	local rendered = 0
	for _, parsed in ipairs(tables) do
		local blocks = Layout.render(parsed, config, win)
		for _, block in ipairs(blocks) do
			if not focused(parsed, block.source_row) and place(buf, block, config.priority) then
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
