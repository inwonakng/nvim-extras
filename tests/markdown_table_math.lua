-- Requires markdown, markdown_inline, and latex Tree-sitter parsers.
-- Run with NVIM_EXTRAS_TABLE_FIRST=1 as well to exercise both setup orders.
local finished = false
local function fail(message)
	if not finished then
		finished = true
		io.stderr:write(message .. "\n")
		vim.cmd("cquit")
	end
end
vim.defer_fn(function() fail("Table math tests timed out") end, 20000)
local thread
local function resume()
	local ok, err = coroutine.resume(thread)
	if not ok then fail(debug.traceback(thread, tostring(err))) end
end
local function pause()
	vim.defer_fn(resume, 10)
	coroutine.yield()
end
local function wait_for(predicate, message)
	local deadline = vim.uv.hrtime() + 2000000000
	while not predicate() do
		assert(vim.uv.hrtime() < deadline, message)
		pause()
	end
end
local function equal(expected, actual, message)
	assert(vim.deep_equal(expected, actual), message .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
end

thread = coroutine.create(function()
	vim.opt.runtimepath:prepend(vim.fn.getcwd())
	vim.o.columns = 110
	vim.o.lines = 40
	vim.wo.number = false
	vim.wo.signcolumn = "no"
	vim.wo.concealcursor = "nvic"
	local buf = vim.api.nvim_get_current_buf()
	local source = {
		"before", "", "| Dataset | Average $T_1(x)=x$ | Average $T_2(x)=2x^2-1$ |",
		"|---|---:|---:|", "| Half $-1$, half $+1$ | $0$ | $+1$ |",
		"| All $0$ | $0$ | $-1$ |", "", "outside $p$", "after",
	}
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	vim.bo.filetype = "markdown"

	-- Control conversion completion to test ownership before/after async results.
	local jobs = {}
	require("latex_renderer.utftex").convert = function(text, callback)
		local job = { callback = callback }
		jobs[text] = jobs[text] or {}
		jobs[text][#jobs[text] + 1] = job
		return function() job.cancelled = true end
	end
	local function complete(text, output, baseline)
		wait_for(function() return jobs[text] ~= nil end, "No conversion for " .. text)
		local pending = jobs[text]
		jobs[text] = nil
		for _, job in ipairs(pending) do
			if not job.cancelled then job.callback({ output = output, baseline = baseline or 1 }) end
		end
	end
	local math_renderer = require("latex_renderer")
	local tables = require("markdown_table_renderer")
	if vim.env.NVIM_EXTRAS_TABLE_FIRST == "1" then
		tables.setup({ debounce_ms = 0 })
		pause()
		math_renderer.setup({ debounce_ms = 0 })
	else
		math_renderer.setup({ debounce_ms = 0 })
		pause()
		tables.setup({ debounce_ms = 0 })
	end
	local function screen()
		vim.cmd("redraw!")
		local lines = {}
		for row = 1, vim.o.lines - 2 do
			local text = {}
			for col = 1, vim.o.columns do text[#text + 1] = vim.fn.screenstring(row, col) end
			lines[#lines + 1] = table.concat(text):gsub("%s+$", "")
		end
		return table.concat(lines, "\n")
	end
	local function contains(text, fragment)
		assert(text:find(fragment, 1, true), "Missing screen text: " .. fragment .. "\n" .. text)
	end
	local function marks(namespace)
		return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
	end
	local math_ns = vim.api.nvim_create_namespace("latex-renderer-inline")
	local function table_rows()
		local rows = {}
		for _, mark in ipairs(marks(tables.namespace())) do rows[#rows + 1] = mark[2] end
		return rows
	end
	local function move(line)
		vim.api.nvim_win_set_cursor(0, { line, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
	end
	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function unchanged()
		equal(source, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "Rendering changed source")
	end
	local function no_table_math_marks()
		for _, mark in ipairs(marks(math_ns)) do
			assert(mark[2] < 2 or mark[2] > 5, "Standalone math decoration on table row")
		end
	end
	complete("T_1(x)=x", "T₁(x)=x")
	complete("T_2(x)=2x^2-1", "T₂(x)=2x²-1")
	complete("-1", "-1")
	complete("+1", "+1")
	complete("0", "0")
	complete("p", "P")
	wait_for(function() return #table_rows() == 4 and screen():find("Average T₁(x)=x", 1, true) end, "Converted math never entered table layout")
	local view = screen()
	contains(view, "│ Dataset          │ Average T₁(x)=x │ Average T₂(x)=2x²-1 │")
	contains(view, "│ Half -1, half +1 │               0 │                  +1 │")
	contains(view, "│ All 0            │               0 │                  -1 │")
	contains(view, "outside P")
	assert(not view:find("$", 1, true), "Raw math leaked into rendered table\n" .. view)
	no_table_math_marks()
	unchanged()

	move(5)
	wait_for(function() return not vim.tbl_contains(table_rows(), 4) end, "Cursor row not revealed")
	contains(screen(), source[5])
	no_table_math_marks()
	for _, editing in ipairs({ { "startinsert", "i" }, { "startreplace", "R" } }) do
		vim.cmd(editing[1])
		wait_for(function() return vim.api.nvim_get_mode().mode == editing[2] end, "Editing mode did not start")
		wait_for(function() return #table_rows() == 0 end, "Editing did not reveal whole table")
		contains(screen(), source[3])
		contains(screen(), source[6])
		no_table_math_marks()
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "t", false)
		wait_for(function() return vim.api.nvim_get_mode().mode == "n" end, "Editing mode did not end")
	end
	for _, visual in ipairs({ "v", "V", "<C-v>" }) do
		move(1)
		keys(visual .. "8j")
		wait_for(function() return #table_rows() == 0 end, "Selection did not reveal table")
		contains(screen(), source[3])
		no_table_math_marks()
		keys("<Esc>")
	end
	move(1)
	wait_for(function() return #table_rows() == 4 end, "Table did not restore")

	-- An inactive window's cursor must not suppress math inside a rendered cell.
	move(5)
	local original_win = vim.api.nvim_get_current_win()
	vim.cmd("vsplit")
	local split_win = vim.api.nvim_get_current_win()
	move(6)
	wait_for(function() return vim.deep_equal({ 2, 3, 4 }, table_rows()) end, "Active split did not determine revealed row")
	contains(screen(), source[6])
	no_table_math_marks()
	vim.api.nvim_set_current_win(original_win)
	wait_for(function() return vim.deep_equal({ 2, 3, 5 }, table_rows()) end, "Window switch did not restore ownership")
	no_table_math_marks()
	vim.api.nvim_win_close(split_win, true)
	move(1)
	wait_for(function() return #table_rows() == 4 end, "Table did not restore after closing split")

	-- Detach and reattach either renderer, preserving the independent module paths.
	tables.detach(buf)
	wait_for(function() return #marks(math_ns) > 1 end, "Math did not resume after table detach")
	tables.attach(buf)
	wait_for(function() return #table_rows() == 4 end, "Table did not reattach")
	no_table_math_marks()
	math_renderer.detach(buf)
	wait_for(function() return screen():find("Average $T_1(x)=x$", 1, true) end, "Table retained detached math results")
	math_renderer.attach(buf)
	complete("T_1(x)=x", "T₁(x)=x")
	complete("T_2(x)=2x^2-1", "T₂(x)=2x²-1")
	complete("-1", "-1")
	complete("+1", "+1")
	complete("0", "0")
	complete("p", "P")
	wait_for(function() return screen():find("Average T₁(x)=x", 1, true) end, "Math did not return after reattach")

	-- Math is an indivisible, baseline-aware box. Prose shares its baseline;
	-- other cells and every fraction line remain inside the table borders.
	source = { "before", "", "| **Name** | Value |", "|---|---:|", "| value $\\frac{1}{2}$ end | $q$ |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	complete("\\frac{1}{2}", "1\n─\n2", 2)
	complete("q", "Q")
	wait_for(function() return screen():find("value ─ end", 1, true) end, "Fraction baseline missing")
	view = screen()
	contains(view, "│ Name        │  Value │")
	contains(view, "│       1     │      Q │\n│ value ─ end │        │\n│       2     │        │")
	assert(not view:find("frac", 1, true), "Raw fraction remained in cell")
	unchanged()
	vim.o.columns = 22
	vim.api.nvim_exec_autocmds("VimResized", {})
	wait_for(function() return screen():find("│ value ─ │", 1, true) end, "Narrow table did not wrap")
	view = screen()
	contains(view, "│       1 │")
	contains(view, "│ value ─ │")
	contains(view, "│       2 │")
	contains(view, "│ end     │")
	unchanged()
	vim.o.columns = 110
	vim.api.nvim_exec_autocmds("VimResized", {})

	-- Multiple formulas share a baseline even when their top/bottom extents
	-- differ. Width is the widest output line, not just the short baseline.
	source = { "before", "", "| Math | Other |", "|---|---|", "| $u$+$v$ | z |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	complete("u", "12345678\n─\n2", 2)
	complete("v", "a\nb", 1)
	wait_for(function() return screen():find("─       +a", 1, true) end, "Multiple formulas lost their common baseline")
	view = screen()
	contains(view, "│ 12345678   │")
	contains(view, "│ ─       +a │")
	contains(view, "│ 2        b │")
	unchanged()

	-- Code spans and escaped dollar signs are not converted; identical formulas
	-- in different cells still use their own source ranges.
	source = { "before", "", "| `cost $x$` | \\$5 |", "|---|---|", "| $r$ | **$r$** |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	complete("r", "R")
	wait_for(function() return screen():find("│ R", 1, true) end, "Repeated formulas not converted")
	view = screen()
	contains(view, "cost $x$")
	contains(view, "$5")
	assert(jobs.x == nil, "Code-span math was sent to converter")
	assert(not view:find("$r$", 1, true), "Repeated formula remained raw")
	unchanged()

	-- Byte offsets include indentation, Unicode, trimmed padding, and pipes
	-- inside code spans; cell-local string offsets are not screen columns.
	source = { "before", "", "  | **é** $s$ | `a|b` $s$ |", "  |---|---|", "  | $s$ | tail |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	complete("s", "S")
	wait_for(function() return screen():find("é S", 1, true) end, "Indented Unicode cell not converted")
	view = screen()
	contains(view, "a|b S")
	assert(not view:find("$s$", 1, true), "Math offsets were wrong after a code-span pipe")
	unchanged()

	-- Completion during editing/selection must not decorate revealed rows.
	source = { "before", "", "| $late$ | B |", "|---|---|", "| $late$ | x |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	wait_for(function() return jobs.late ~= nil end, "Late conversion not started")
	move(5)
	vim.cmd("startinsert")
	wait_for(function() return vim.api.nvim_get_mode().mode == "i" end, "Insert did not start")
	complete("late", "LATE")
	wait_for(function() return #table_rows() == 0 end, "Insert did not reveal late result's table")
	contains(screen(), source[3])
	equal({}, marks(math_ns), "Late completion decorated revealed math")
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "t", false)
	wait_for(function() return vim.api.nvim_get_mode().mode == "n" end, "Insert did not end")
	move(1)
	wait_for(function() return screen():find("LATE", 1, true) end, "Late result did not render after leaving table")
	unchanged()

	-- Failed conversions retain readable source and can be retried normally.
	source = { "before", "", "| $bad$ | B |", "|---|---|", "| x | y |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	wait_for(function() return jobs.bad ~= nil end, "Failed conversion not started")
	local bad = jobs.bad
	jobs.bad = nil
	local notify = vim.notify
	local warnings = {}
	vim.notify = function(message) warnings[#warnings + 1] = message end
	for _, job in ipairs(bad) do job.callback(nil, "test conversion failure") end
	vim.notify = notify
	equal(1, #warnings, "Conversion failure should be reported once")
	contains(screen(), "$bad$")
	vim.cmd("LatexRendererRefresh")
	complete("bad", "RECOVERED")
	wait_for(function() return screen():find("RECOVERED", 1, true) end, "Failed formula did not recover on refresh")
	unchanged()

	-- Results arriving after an edit must not replace new source at old offsets.
	source = { "before", "", "| A | B |", "|---|---|", "| $old$ | x |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	wait_for(function() return jobs.old ~= nil end, "Old conversion not started")
	local old = jobs.old
	source[5] = "| $new$ | x |"
	vim.api.nvim_buf_set_lines(buf, 4, 5, false, { source[5] })
	for _, job in ipairs(old) do job.callback({ output = "STALE", baseline = 1 }) end
	assert(not screen():find("STALE", 1, true), "Stale async result was displayed")
	complete("new", "NEW")
	wait_for(function() return screen():find("NEW", 1, true) end, "Edited formula not converted")
	assert(not screen():find("STALE", 1, true), "Stale result survived reparse")
	unchanged()

	-- Display-style math is not a table-cell image: neither completion nor
	-- ownership changes may conceal the source row or add image virtual lines.
	local display_callback
	require("latex_renderer.compiler").compile = function(_, _, callback)
		display_callback = callback
		return function() end
	end
	local kitty = require("latex_renderer.kitty")
	kitty.cell_size = function() return 8, 16 end
	kitty.transmit = function() end
	kitty.place = function() end
	kitty.delete = function() end
	kitty.placeholder_lines = function() return { { { "DISPLAY" } } } end
	source = { "before", "", "| $x$ | $$y$$ |", "|---|---|", "| a | b |", "", "after" }
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	complete("x", "X")
	wait_for(function() return display_callback ~= nil end, "Display conversion not started")
	move(3)
	wait_for(function() return #table_rows() == 2 end, "Display source row not revealed")
	display_callback({ path = "unused.png", width_px = 8, height_px = 16 })
	local display_ns = vim.api.nvim_create_namespace("latex-renderer-display")
	equal({}, marks(display_ns), "Display completion decorated a table-controlled row")
	contains(screen(), source[3])
	move(1)
	wait_for(function() return #table_rows() == 3 end, "Display table did not render")
	contains(screen(), "$$y$$")
	tables.detach(buf)
	wait_for(function() return #marks(display_ns) > 0 end, "Standalone display did not resume after table detach")
	tables.attach(buf)
	wait_for(function() return #table_rows() == 3 and #marks(display_ns) == 0 end, "Table reattach did not remove display decorations")
	unchanged()

	finished = true
	io.stdout:write("Markdown table math tests passed\n")
	vim.cmd("qa!")
end)
vim.schedule(resume)
