local M = {}

local cache = {}
local cache_size = 0
local cache_limit = 2048
local highlight_query

local function char_length(text, index)
	local byte = text:byte(index)
	if not byte or byte < 0x80 then
		return 1
	elseif byte < 0xE0 then
		return 2
	elseif byte < 0xF0 then
		return 3
	end
	return 4
end

local function ignored_capture(name)
	return name == "conceal" or name == "nospell" or name == "spell" or name:sub(1, 1) == "_"
end

local function plain_units(text)
	local units = {}
	local index = 1
	while index <= #text do
		local length = char_length(text, index)
		units[#units + 1] = { text = text:sub(index, index + length - 1) }
		index = index + length
	end
	return units
end

local function parse(text)
	local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown_inline")
	if not ok then
		return plain_units(text)
	end
	if not highlight_query then
		highlight_query = vim.treesitter.query.get("markdown_inline", "highlights")
	end
	if not highlight_query then
		return plain_units(text)
	end
	local trees = parser:parse()
	local tree = trees and trees[1]
	if not tree then
		return plain_units(text)
	end

	local hidden = {}
	local highlights = {}
	local replacements = {}
	for capture_id, node, metadata in highlight_query:iter_captures(tree:root(), text, 0, -1) do
		local capture_metadata = metadata[capture_id]
		local range = vim.treesitter.get_range(node, text, capture_metadata)
		local start_row, start_col, end_row, end_col = range[1], range[2], range[4], range[5]
		if start_row == 0 and end_row == 0 then
			local name = highlight_query.captures[capture_id]
			local conceal = metadata.conceal
			if conceal == nil and capture_metadata then
				conceal = capture_metadata.conceal
			end
			if name == "conceal" or conceal ~= nil then
				for index = start_col + 1, end_col do
					hidden[index] = true
				end
				if type(conceal) == "string" and conceal ~= "" then
					replacements[start_col + 1] = { text = conceal, hl = "@" .. name }
				end
			elseif not ignored_capture(name) then
				for index = start_col + 1, end_col do
					highlights[index] = "@" .. name
				end
			end
		end
	end

	-- Tree-sitter highlights escapes but does not conceal their leading slash.
	for index = 1, #text - 1 do
		if text:sub(index, index) == "\\" and highlights[index] == "@string.escape" then
			hidden[index] = true
		end
	end

	local units = {}
	local index = 1
	while index <= #text do
		local replacement = replacements[index]
		if replacement then
			for _, unit in ipairs(plain_units(replacement.text)) do
				unit.hl = replacement.hl
				units[#units + 1] = unit
			end
		end
		local length = char_length(text, index)
		if not hidden[index] then
			units[#units + 1] = {
				text = text:sub(index, index + length - 1),
				hl = highlights[index],
			}
		end
		index = index + length
	end
	return units
end

function M.units(text)
	text = text or ""
	local cached = cache[text]
	if cached then
		return cached
	end
	local units = parse(text)
	if cache_size >= cache_limit then
		cache = {}
		cache_size = 0
	end
	cache[text] = units
	cache_size = cache_size + 1
	return units
end

function M.clear_cache()
	cache = {}
	cache_size = 0
end

return M
