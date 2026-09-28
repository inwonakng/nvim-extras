local M = {}

local namespace = vim.api.nvim_create_namespace("latex-renderer-inline")

local function spaces(count)
	return string.rep(" ", math.max(0, count))
end

function M.apply(buf, entries, focused)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	local rows = {}
	for _, entry in pairs(entries) do
		if entry.output and not focused(entry.item) then
			local row = entry.item.start_row
			rows[row] = rows[row] or {}
			rows[row][#rows[row] + 1] = entry
		end
	end

	for row, row_entries in pairs(rows) do
		table.sort(row_entries, function(left, right)
			return left.item.start_col < right.item.start_col
		end)
		local source_line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		local lines_above = {}
		local lines_below = {}
		local current_width = 0

		for _, entry in ipairs(row_entries) do
			local output = vim.split(entry.output, "\n", { plain = true })
			local baseline = entry.baseline
			vim.api.nvim_buf_set_extmark(buf, namespace, entry.item.start_row, entry.item.start_col, {
				end_row = entry.item.end_row,
				end_col = entry.item.end_col,
				conceal = "",
				virt_text = { { output[baseline], "@markup.math" } },
				virt_text_pos = "inline",
				priority = 250,
				strict = false,
			})

			local width = 1
			for _, line in ipairs(output) do
				width = math.max(width, vim.fn.strdisplaywidth(line))
			end
			for index, line in ipairs(output) do
				output[index] = line .. spaces(width - vim.fn.strdisplaywidth(line))
			end

			local source_prefix = source_line:sub(1, entry.item.start_col)
			local column = vim.fn.strdisplaywidth(source_prefix)
			local prefix = math.max(column - current_width, current_width == 0 and 0 or 1)
			local above = baseline - 1
			local below = #output - baseline

			while #lines_above < above do
				table.insert(lines_above, 1, spaces(current_width))
			end
			while #lines_below < below do
				lines_below[#lines_below + 1] = spaces(current_width)
			end
			for index, line in ipairs(lines_above) do
				local output_index = index - (#lines_above - above)
				local body = output[output_index] or spaces(width)
				lines_above[index] = line .. spaces(prefix) .. body
			end
			for index, line in ipairs(lines_below) do
				local output_index = index + (#output - below)
				local body = output[output_index] or spaces(width)
				lines_below[index] = line .. spaces(prefix) .. body
			end
			current_width = current_width + prefix + width
		end

		local function add_virtual_lines(lines, above)
			if #lines == 0 then
				return
			end
			local virtual_lines = {}
			for _, line in ipairs(lines) do
				virtual_lines[#virtual_lines + 1] = { { line, "@markup.math" } }
			end
			vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, {
				virt_lines = virtual_lines,
				virt_lines_above = above,
				priority = 250,
				strict = false,
			})
		end

		add_virtual_lines(lines_above, true)
		add_virtual_lines(lines_below, false)
	end
end

function M.clear(buf)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
end

return M
