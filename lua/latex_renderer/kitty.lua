local bit = require("bit")

local M = {}

local placeholder = vim.fn.nr2char(0x10EEEE)
local diacritic_codepoints = vim.split(
	"0305,030D,030E,0310,0312,033D,033E,033F,0346,034A,034B,034C,0350,0351,0352,0357,035B,0363,0364,0365,0366,0367,0368,0369,036A,036B,036C,036D,036E,036F,0483,0484,0485,0486,0487,0592,0593,0594,0595,0597,0598,0599,059C,059D,059E,059F,05A0,05A1,05A8,05A9,05AB,05AC,05AF,05C4,0610,0611,0612,0613,0614,0615,0616,0617,0657,0658,0659,065A,065B,065D,065E,06D6,06D7,06D8,06D9,06DA,06DB,06DC,06DF,06E0,06E1,06E2,06E4,06E7,06E8,06EB,06EC,0730,0732,0733,0735,0736,073A,073D,073F,0740,0741,0743,0745,0747,0749,074A,07EB,07EC,07ED,07EE,07EF,07F0,07F1,07F3,0816,0817,0818,0819,081B,081C,081D,081E,081F,0820,0821,0822,0823,0825,0826,0827,0829,082A,082B,082C,082D",
	",",
	{ plain = true }
)
local diacritics = {}
for index, codepoint in ipairs(diacritic_codepoints) do
	diacritics[index] = vim.fn.nr2char(tonumber(codepoint, 16))
end

local next_id = 30
local process_bits
local cell_size
local ffi_declared = false

local function id_prefix()
	if process_bits then
		return process_bits
	end
	local pid = vim.fn.getpid()
	process_bits = bit.band(bit.bxor(pid, bit.rshift(pid, 5), bit.rshift(pid, 10)), 0x3FF)
	return process_bits
end

function M.next_id()
	next_id = next_id + 1
	assert(next_id < 0x4000, "latex renderer exhausted Kitty image IDs")
	return bit.bor(bit.lshift(id_prefix(), 14), next_id)
end

function M.tmux_depth()
	if not vim.env.TMUX or vim.env.TMUX == "" then
		return 0
	end
	local depth = tonumber(vim.env.TMUX_NEST_COUNT) or 1
	return math.max(1, math.floor(depth))
end

function M.tmux_wrap(data, depth)
	depth = depth == nil and M.tmux_depth() or depth
	assert(depth >= 0 and depth == math.floor(depth), "tmux depth must be a non-negative integer")
	for _ = 1, depth do
		data = "\027Ptmux;" .. data:gsub("\027", "\027\027") .. "\027\\"
	end
	return data
end

function M.encode_request(control, payload)
	local keys = vim.tbl_keys(control)
	table.sort(keys)
	local fields = {}
	for _, key in ipairs(keys) do
		fields[#fields + 1] = key .. "=" .. tostring(control[key])
	end
	return "\027_G" .. table.concat(fields, ",") .. (payload and (";" .. payload) or "") .. "\027\\"
end

function M.emit(data)
	if #vim.api.nvim_list_uis() == 0 then
		return false
	end
	vim.api.nvim_ui_send(M.tmux_wrap(data))
	return true
end

function M.transmit(path, image_id)
	return M.emit(M.encode_request({ a = "t", f = 100, i = image_id, q = 2, t = "f" }, vim.base64.encode(path)))
end

function M.place(image_id, width, height)
	return M.emit(M.encode_request({
		C = 1,
		U = 1,
		a = "p",
		c = width,
		i = image_id,
		q = 2,
		r = height,
	}))
end

function M.delete(image_id)
	return M.emit(M.encode_request({ a = "d", d = "I", i = image_id, q = 2 }))
end

function M.placeholder_lines(width, height, image_id, padding)
	assert(width <= #diacritics and height <= #diacritics, "Kitty placeholder grid exceeds its alphabet")
	local highlight = ("LatexRendererImage%d"):format(image_id)
	vim.api.nvim_set_hl(0, highlight, {
		fg = ("#%06x"):format(image_id),
	})

	local lines = {}
	padding = math.max(0, padding or 0)
	for row = 1, height do
		local cells = {}
		for col = 1, width do
			cells[#cells + 1] = placeholder .. diacritics[row] .. diacritics[col]
		end
		lines[#lines + 1] = {
			{ string.rep(" ", padding), "Normal" },
			{ table.concat(cells), highlight },
		}
	end
	return lines
end

function M.invalidate_cell_size()
	cell_size = nil
end

function M.cell_size()
	if cell_size then
		return cell_size.width, cell_size.height
	end

	local width, height = 10, 20
	pcall(function()
		local ffi = require("ffi")
		if not ffi_declared then
			pcall(ffi.cdef, [[
				typedef struct {
					unsigned short row;
					unsigned short col;
					unsigned short xpixel;
					unsigned short ypixel;
				} latex_renderer_winsize;
				int ioctl(int, int, ...);
			]])
			ffi_declared = true
		end
		local request
		if vim.fn.has("linux") == 1 then
			request = 0x5413
		elseif vim.fn.has("mac") == 1 or vim.fn.has("bsd") == 1 then
			request = 0x40087468
		end
		if not request then
			return
		end
		local size = ffi.new("latex_renderer_winsize")
		if ffi.C.ioctl(1, request, size) == 0 and size.col > 0 and size.row > 0 and size.xpixel > 0 and size.ypixel > 0 then
			width = tonumber(size.xpixel) / tonumber(size.col)
			height = tonumber(size.ypixel) / tonumber(size.row)
		end
	end)
	cell_size = { width = width, height = height }
	return width, height
end

return M
