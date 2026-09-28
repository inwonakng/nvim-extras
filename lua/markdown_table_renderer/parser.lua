local M = {}

local table_query

local function trim(text)
	return (text or ""):gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
end

local function backtick_run(text, index)
	local finish = index
	while text:sub(finish + 1, finish + 1) == "`" do
		finish = finish + 1
	end
	return finish - index + 1, finish
end

local function pipe_positions(text)
	local runs = {}
	local remaining = {}
	local escaped = false
	local index = 1

	while index <= #text do
		local char = text:sub(index, index)
		if char == "`" then
			local count, finish = backtick_run(text, index)
			runs[#runs + 1] = { start_col = index, end_col = finish, count = count, escaped = escaped }
			remaining[count] = (remaining[count] or 0) + 1
			escaped = false
			index = finish + 1
		elseif escaped then
			escaped = false
			index = index + 1
		elseif char == "\\" then
			escaped = true
			index = index + 1
		else
			index = index + 1
		end
	end

	local positions = {}
	local run_index = 1
	local code_ticks
	escaped = false
	index = 1
	while index <= #text do
		local run = runs[run_index]
		if run and run.start_col == index then
			remaining[run.count] = remaining[run.count] - 1
			if code_ticks == run.count then
				code_ticks = nil
			elseif not code_ticks and not run.escaped and remaining[run.count] > 0 then
				code_ticks = run.count
			end
			escaped = false
			index = run.end_col + 1
			run_index = run_index + 1
		else
			local char = text:sub(index, index)
			if escaped then
				escaped = false
			elseif char == "\\" and not code_ticks then
				escaped = true
			elseif char == "|" and not code_ticks then
				positions[#positions + 1] = index
			end
			index = index + 1
		end
	end
	return positions
end

local function split_row(text)
	local positions = pipe_positions(text)
	local spans = {}
	local start_col = 1
	for _, position in ipairs(positions) do
		spans[#spans + 1] = { start_col, position - 1 }
		start_col = position + 1
	end
	spans[#spans + 1] = { start_col, #text }

	if positions[1] and text:sub(1, positions[1] - 1):match("^[ \t]*$") then
		table.remove(spans, 1)
	end
	local last_pipe = positions[#positions]
	if last_pipe and text:sub(last_pipe + 1):match("^[ \t]*$") and #spans > 1 then
		table.remove(spans)
	end

	local cells = {}
	for _, span in ipairs(spans) do
		cells[#cells + 1] = trim(text:sub(span[1], span[2]))
	end
	return cells, #positions
end

local function alignment(cell)
	local value = trim(cell):gsub("[ \t]", "")
	if not value:match("^:?-+:?$") then
		return nil
	end
	if value:sub(1, 1) == ":" and value:sub(-1) == ":" then
		return "center"
	elseif value:sub(-1) == ":" then
		return "right"
	end
	return "left"
end

local function row_text(node, buf)
	local text = vim.treesitter.get_node_text(node, buf)
	return type(text) == "string" and text or ""
end

local function parse_table(node, buf)
	local header_node
	local delimiter_node
	local row_nodes = {}
	for index = 0, node:named_child_count() - 1 do
		local child = node:named_child(index)
		local kind = child:type()
		if kind == "pipe_table_header" then
			header_node = child
		elseif kind == "pipe_table_delimiter_row" then
			delimiter_node = child
		elseif kind == "pipe_table_row" then
			row_nodes[#row_nodes + 1] = child
		end
	end
	if not header_node or not delimiter_node then
		return nil
	end

	local header, header_pipes = split_row(row_text(header_node, buf))
	local delimiter = split_row(row_text(delimiter_node, buf))
	if header_pipes == 0 or #header == 0 or #delimiter ~= #header then
		return nil
	end

	local alignments = {}
	for index, cell in ipairs(delimiter) do
		alignments[index] = alignment(cell)
		if not alignments[index] then
			return nil
		end
	end

	local rows = {}
	local _, start_col = header_node:range()
	local start_row = select(1, header_node:range())
	local end_row = select(1, delimiter_node:range()) + 1
	for _, row_node in ipairs(row_nodes) do
		local cells, pipes = split_row(row_text(row_node, buf))
		if (#header > 1 and pipes == 0) or #cells > #header then
			return nil
		end
		while #cells < #header do
			cells[#cells + 1] = ""
		end
		rows[#rows + 1] = cells
		end_row = select(1, row_node:range()) + 1
	end

	local source_line = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1] or ""
	return {
		id = ("%d:%d"):format(start_row, end_row),
		start_row = start_row,
		end_row = end_row,
		prefix = source_line:sub(1, start_col),
		header = header,
		alignments = alignments,
		rows = rows,
	}
end

function M.scan(buf)
	if not table_query then
		table_query = vim.treesitter.query.parse("markdown", "(pipe_table) @table")
	end
	local parser = vim.treesitter.get_parser(buf, "markdown")
	local trees = parser:parse(true)
	local tree = trees and trees[1]
	if not tree then
		return {}
	end

	local tables = {}
	for _, node in table_query:iter_captures(tree:root(), buf) do
		local parsed = parse_table(node, buf)
		if parsed then
			tables[#tables + 1] = parsed
		end
	end
	table.sort(tables, function(left, right)
		return left.start_row < right.start_row
	end)
	return tables
end

M.split_row = split_row

return M
