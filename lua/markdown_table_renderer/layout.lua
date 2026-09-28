local Inline = require("markdown_table_renderer.inline")

local M = {}

local borders = {
	top = { "╭", "┬", "╮" },
	middle = { "├", "┼", "┤" },
	bottom = { "╰", "┴", "╯" },
	vertical = "│",
	horizontal = "─",
}

local function width(text)
	return vim.fn.strdisplaywidth(text)
end

local function unit_width(unit)
	return width(unit.text)
end

local function append_chunk(chunks, text, highlight)
	if text == "" then
		return
	end
	local previous = chunks[#chunks]
	if previous and previous[2] == highlight then
		previous[1] = previous[1] .. text
	else
		chunks[#chunks + 1] = { text, highlight }
	end
end

local function append_units(chunks, units, fallback)
	for _, unit in ipairs(units) do
		append_chunk(chunks, unit.text, unit.hl or fallback)
	end
end

local function units_width(units)
	local result = 0
	for _, unit in ipairs(units) do
		result = result + unit_width(unit)
	end
	return result
end

local function words(units)
	local result = {}
	local current = {}
	for _, unit in ipairs(units) do
		if unit.text:match("^%s+$") then
			if #current > 0 then
				result[#result + 1] = current
				current = {}
			end
		else
			current[#current + 1] = unit
		end
	end
	if #current > 0 then
		result[#result + 1] = current
	end
	return result
end

local function split_word(word, limit)
	local pieces = {}
	local current = {}
	local current_width = 0
	for _, unit in ipairs(word) do
		local next_width = unit_width(unit)
		if #current > 0 and current_width + next_width > limit then
			pieces[#pieces + 1] = current
			current = {}
			current_width = 0
		end
		current[#current + 1] = unit
		current_width = current_width + next_width
	end
	if #current > 0 then
		pieces[#pieces + 1] = current
	end
	return pieces
end

local function wrap(units, limit)
	local lines = {}
	local current = {}
	local current_width = 0
	local first_word = true

	local function flush()
		if #current > 0 then
			lines[#lines + 1] = current
			current = {}
			current_width = 0
		end
	end

	for _, word in ipairs(words(units)) do
		local pieces = split_word(word, limit)
		for piece_index, piece in ipairs(pieces) do
			local piece_width = units_width(piece)
			local needs_space = not first_word and piece_index == 1
			local space_width = needs_space and 1 or 0
			if #current > 0 and current_width + space_width + piece_width > limit then
				flush()
				space_width = 0
			end
			if piece_index > 1 then
				flush()
				space_width = 0
			end
			if space_width == 1 then
				current[#current + 1] = { text = " " }
				current_width = current_width + 1
			end
			vim.list_extend(current, piece)
			current_width = current_width + piece_width
			if piece_index < #pieces then
				flush()
			end
		end
		first_word = false
	end
	flush()
	if #lines == 0 then
		lines[1] = {}
	end
	return lines
end

local function natural_width(units)
	local result = 0
	for index, word in ipairs(words(units)) do
		if index > 1 then
			result = result + 1
		end
		result = result + units_width(word)
	end
	return math.max(1, result)
end

local function text_width(win)
	local info = vim.fn.getwininfo(win)[1] or {}
	return math.max(1, vim.api.nvim_win_get_width(win) - (info.textoff or 0))
end

local function sum(values)
	local result = 0
	for _, value in ipairs(values) do
		result = result + value
	end
	return result
end

local function column_widths(parsed, cells, config, win)
	local count = #parsed.header
	local natural = {}
	local glyph_floor = {}
	for column = 1, count do
		natural[column] = 1
		glyph_floor[column] = 1
	end
	for _, row in ipairs(cells) do
		for column = 1, count do
			local units = row[column] or {}
			natural[column] = math.max(natural[column], natural_width(units))
			for _, unit in ipairs(units) do
				glyph_floor[column] = math.max(glyph_floor[column], unit_width(unit))
			end
		end
	end

	local available = math.max(1, math.floor(text_width(win) * config.max_width_ratio) - width(parsed.prefix))
	local content_budget = math.max(count, available - (count * 3 + 1))
	local preferred_min = math.max(1, math.floor(config.min_col_width))
	local effective_min = math.max(1, math.min(preferred_min, math.floor(content_budget / count)))
	local widths = {}
	local minimums = {}
	for column = 1, count do
		minimums[column] = math.max(effective_min, glyph_floor[column])
		widths[column] = math.max(minimums[column], math.min(natural[column], config.max_col_width))
	end

	while sum(widths) > content_budget do
		local candidate
		for column = 1, count do
			if widths[column] > minimums[column] and (not candidate or widths[column] > widths[candidate]) then
				candidate = column
			end
		end
		if not candidate then
			break
		end
		widths[candidate] = widths[candidate] - 1
	end
	return widths
end

local function border_line(prefix, parts, widths)
	local chunks = {}
	append_chunk(chunks, prefix, "Comment")
	append_chunk(chunks, parts[1], "MarkdownTableBorder")
	for column, column_width in ipairs(widths) do
		append_chunk(chunks, borders.horizontal:rep(column_width + 2), "MarkdownTableBorder")
		append_chunk(chunks, column == #widths and parts[3] or parts[2], "MarkdownTableBorder")
	end
	return chunks
end

local function render_row(prefix, row, widths, alignments, fallback)
	local wrapped = {}
	local height = 1
	for column, column_width in ipairs(widths) do
		wrapped[column] = wrap(row[column] or {}, column_width)
		height = math.max(height, #wrapped[column])
	end

	local result = {}
	for line_index = 1, height do
		local chunks = {}
		append_chunk(chunks, prefix, "Comment")
		append_chunk(chunks, borders.vertical, "MarkdownTableBorder")
		for column, column_width in ipairs(widths) do
			local units = wrapped[column][line_index] or {}
			local content_width = units_width(units)
			local spare = math.max(0, column_width - content_width)
			local left = 0
			if alignments[column] == "right" then
				left = spare
			elseif alignments[column] == "center" then
				left = math.floor(spare / 2)
			end
			local right = spare - left
			append_chunk(chunks, " " .. string.rep(" ", left), fallback)
			append_units(chunks, units, fallback)
			append_chunk(chunks, string.rep(" ", right) .. " ", fallback)
			append_chunk(chunks, borders.vertical, "MarkdownTableBorder")
		end
		result[#result + 1] = chunks
	end
	return result
end

function M.render(parsed, config, win)
	local cell_units = {}
	local header = {}
	for column, cell in ipairs(parsed.header) do
		header[column] = Inline.units(cell)
	end
	cell_units[1] = header
	for _, row in ipairs(parsed.rows) do
		local converted = {}
		for column, cell in ipairs(row) do
			converted[column] = Inline.units(cell)
		end
		cell_units[#cell_units + 1] = converted
	end

	local widths = column_widths(parsed, cell_units, config, win)
	local lines = { border_line(parsed.prefix, borders.top, widths) }
	vim.list_extend(lines, render_row(parsed.prefix, header, widths, parsed.alignments, "MarkdownTableHeader"))
	lines[#lines + 1] = border_line(parsed.prefix, borders.middle, widths)
	for index = 2, #cell_units do
		vim.list_extend(lines, render_row(parsed.prefix, cell_units[index], widths, parsed.alignments, "MarkdownTableCell"))
		if config.row_separator and index < #cell_units then
			lines[#lines + 1] = border_line(parsed.prefix, borders.middle, widths)
		end
	end
	lines[#lines + 1] = border_line(parsed.prefix, borders.bottom, widths)
	return lines
end

return M
