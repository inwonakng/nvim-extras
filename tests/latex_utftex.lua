-- Run with: nvim --headless -u NONE -i NONE -l tests/latex_utftex.lua
-- Requires utftex on PATH; no Tree-sitter parsers are needed.
vim.defer_fn(function()
	io.stderr:write("Inline conversion tests timed out\n")
	vim.cmd("cquit 1")
end, 20000)
local ok, err = xpcall(function()
	vim.opt.runtimepath:prepend(vim.fn.getcwd())
	local utftex = require("latex_renderer.utftex")
	assert(utftex.available(), "Tests require utftex on PATH")
	local function equal(expected, actual, message)
		assert(vim.deep_equal(expected, actual), message .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
	end
	local function convert(source)
		local done, converted, failure = false, nil, nil
		utftex.convert(source, function(result, conversion_error)
			converted, failure, done = result, conversion_error, true
		end)
		assert(vim.wait(5000, function() return done end), "Conversion timed out: " .. source)
		assert(converted, failure)
		return converted
	end

	for _, case in ipairs({
		{ "e_{t,j}", "e_{t,j}" },
		{ "x_1+x_2+x^2", "x_1+x_2+x^2" },
		{ "x^{n+1}", "x^{n+1}" },
		{ [[\alpha_{i}+\beta^{n+1}]], "α_{i}+β^{n+1}" },
		{ [[x_{i_{j}}^{\frac{n}{2}}]], [[x_{i_{j}}^{\frac{n}{2}}]] },
		{ [[x_\alpha+y^\beta]], [[x_\alpha+y^\beta]] },
		{ [[x_{a\{b\}c}]], [[x_{a\{b\}c}]] },
		{ "x_ {i, j}^ {n + 1}", "x_ {i, j}^ {n + 1}" },
		{ [[\mathbf{x_{i}}]], "𝐱_{i}" },
		{ "x_{界,é}", "x_{界,é}" },
		{ "x_α+y^β", "x_α+y^β" },
		{ "x_{i,\nj}", "x_{i, j}" },
		{ "x_{i,\tj}", "x_{i, j}" },
		{ "x_{a%b}", "x_{a%b}" },
		{ vim.fn.nr2char(0xE800) .. "+x_{i}", vim.fn.nr2char(0xE800) .. "+x_{i}" },
		{ [[a\_b]], "a_b" },
		{ [[\alpha+\beta]], "α+β" },
	}) do
		equal({ output = case[2], baseline = 1 }, convert(case[1]), "Scripts must retain source notation: " .. case[1])
	end

	-- Literal scripts must reserve their full width before utftex lays out a
	-- fraction, rather than expanding a one-cell placeholder after conversion.
	local fraction = convert([[\frac{x_{i}}{2}]])
	equal("x_{i}\n─────\n  2", fraction.output, "Fraction layout lost script width")
	equal(2, fraction.baseline, "Fraction lost its baseline")
	local root = convert([[\sqrt{x_{i}}]])
	assert(root.output:find("x_{i}", 1, true), "Root argument lost its literal script")
	assert(root.baseline > 1, "Root layout was flattened")

	-- Exercise the reported sentence through conversion and inline extmarks,
	-- with real screen wrapping. Scripts must not create any virtual rows.
	local source = "Each $e_{t,j}$ is a vector in the codebook for position $t$. The selected vectors approximately reconstruct the original embedding:"
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { source, "" })
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	vim.o.columns = 80
	vim.wo.wrap = true
	vim.wo.linebreak = true
	vim.wo.number = false
	vim.wo.signcolumn = "no"
	vim.wo.conceallevel = 2
	vim.wo.concealcursor = "nvic"
	local entries = {}
	for first, formula, last in source:gmatch("()%$(.-)%$()") do
		local result = convert(formula)
		entries[#entries + 1] = {
			item = { start_row = 0, end_row = 0, start_col = first - 1, end_col = last - 1 },
			output = result.output,
			baseline = result.baseline,
		}
	end
	require("latex_renderer.inline").apply(buf, entries, function() return false end)
	local namespace = vim.api.nvim_create_namespace("latex-renderer-inline")
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
		assert(not mark[4].virt_lines, "Scripts created detached virtual rows")
	end
	vim.cmd("redraw!")
	local function screen_row(row)
		local chars = {}
		for col = 1, vim.o.columns do
			chars[#chars + 1] = vim.fn.screenstring(row, col)
		end
		return table.concat(chars)
	end
	assert(screen_row(1):find("Each e_{t,j} is a vector", 1, true), "Script left the first wrapped row")
	assert(screen_row(2):find("embedding:", 1, true), "Fixture did not wrap into two rows")
	vim.wo.wrap = false
	vim.cmd("redraw!")
	assert(screen_row(1):find("Each e_{t,j} is a vector", 1, true), "Unwrapped script left its baseline")
	assert(not screen_row(2):find("embedding:", 1, true), "Fixture still wrapped with nowrap")
	equal({ source, "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "Rendering changed source")
	io.stdout:write("Inline conversion tests passed\n")
end, debug.traceback)
if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
