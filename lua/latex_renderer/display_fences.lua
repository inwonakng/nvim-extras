local M = {}

local delimiters = {
	["$$"] = "$$",
	["\\["] = "\\]",
}

local function delimiter_on_line(line)
	local prefix, token = line:match("^(%s*)(%S+)%s*$")
	if not token then
		return nil
	end
	if token ~= "$$" and token ~= "\\[" and token ~= "\\]" then
		return nil
	end
	return token, #prefix, #prefix + #token
end

local function range_text(lines, start_row, start_col, end_row, end_col)
	local text = {}
	for row = start_row, end_row do
		local line = lines[row + 1]
		if row == start_row then
			line = line:sub(start_col + 1)
		end
		if row == end_row then
			line = line:sub(1, end_col)
		end
		text[#text + 1] = line
	end
	return table.concat(text, "\n")
end

function M.scan(lines, is_protected)
	is_protected = is_protected or function()
		return false
	end

	local items = {}
	local opener
	for index, line in ipairs(lines) do
		local row = index - 1
		local token, start_col, end_col = delimiter_on_line(line)
		if opener then
			if token == opener.close then
				items[#items + 1] = {
					start_row = opener.row,
					start_col = opener.start_col,
					end_row = row,
					end_col = end_col,
					text = range_text(lines, opener.row, opener.start_col, row, end_col),
				}
				opener = nil
			end
		elseif token and delimiters[token] and not is_protected(row, start_col) then
			opener = {
				row = row,
				start_col = start_col,
				close = delimiters[token],
			}
		end
	end
	return items
end

return M
