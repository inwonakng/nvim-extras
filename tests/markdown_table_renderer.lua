-- Run from the checkout with:
-- nvim --headless -u NONE -i NONE -n -c "lua dofile('tests/markdown_table_renderer.lua')"
-- Requires the markdown and markdown_inline Tree-sitter parsers on runtimepath.
local finished = false
local function fail(message)
	if not finished then
		finished = true
		io.stderr:write(message .. "\n")
		vim.cmd("cquit")
	end
end

-- Install before loading the renderer so initialization failures cannot hang.
vim.defer_fn(function()
	fail("Markdown table tests timed out")
end, 15000)

local thread
local function resume()
	local ok, err = coroutine.resume(thread)
	if not ok then
		fail(debug.traceback(thread, tostring(err)))
	end
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
	vim.o.columns = 80
	vim.o.lines = 24
	vim.wo.wrap = true
	vim.wo.number = false
	vim.wo.signcolumn = "no"
	vim.wo.concealcursor = "nvic" -- Reveal must not depend on the user's conceal setting.
	local buf = vim.api.nvim_get_current_buf()
	local source = {
		"before", "", "| A | B |", "| --- | --- |",
		"| long text long text long text | x |", "| c | d |", "", "after",
	}
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
	vim.bo.filetype = "markdown"
	local tables = require("markdown_table_renderer")
	tables.setup({ debounce_ms = 0, max_col_width = 10 })
	local namespace = tables.namespace()

	local function marks()
		return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
	end
	local function rendered_rows()
		local result = {}
		for _, mark in ipairs(marks()) do
			assert(mark[4].conceal_lines == nil, "Buffer rows must never be hidden")
			if mark[4].virt_text then
				result[#result + 1] = mark[2]
			end
		end
		return result
	end
	local function expect_rows(rows)
		wait_for(function()
			return vim.deep_equal(rows, rendered_rows())
		end, "Unexpected rendered rows: " .. vim.inspect(rows))
	end
	local function move(line)
		vim.api.nvim_win_set_cursor(0, { line, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
	end
	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function screen()
		vim.cmd("redraw!")
		local lines = {}
		for row = 1, vim.o.lines - 2 do
			local text = {}
			for col = 1, vim.o.columns do
				text[#text + 1] = vim.fn.screenstring(row, col)
			end
			lines[#lines + 1] = table.concat(text):gsub("%s+$", "")
		end
		return table.concat(lines, "\n")
	end
	local function contains(text, fragment)
		assert(text:find(fragment, 1, true), "Missing screen text: " .. fragment .. "\n" .. text)
	end
	local function unchanged()
		equal(source, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "Rendering changed the Markdown")
		assert(vim.wo.wrap, "Rendering changed wrap")
	end

	expect_rows({ 2, 3, 4, 5 })
	local view = screen()
	contains(view, "╭────────────┬────────╮")
	contains(view, "│ A          │ B      │")
	contains(view, "│ long text  │ x      │")
	contains(view, "│ long text  │        │")
	contains(view, "╰────────────┴────────╯")
	assert(not view:find("| long text", 1, true), "Concealed source leaked into rendering")

	-- Native end-of-line diagnostics must follow the whole rendered row, even
	-- when the warning points into the concealed leftmost cell.
	local diagnostic_ns = vim.api.nvim_create_namespace("markdown-table-renderer-test-diagnostics")
	vim.diagnostic.config({
		virtual_text = {
			spacing = 2,
			prefix = "●",
			format = function() return "" end,
		},
		signs = false,
		underline = true,
	}, diagnostic_ns)
	local diagnostics = {
		{ lnum = 4, col = 2, end_col = 6, message = "Left cell warning", severity = vim.diagnostic.severity.WARN },
		{ lnum = 5, col = 2, end_col = 3, message = "Short row warning", severity = vim.diagnostic.severity.WARN },
	}
	local function diagnostic_after(text, row)
		assert(text:find(vim.pesc(row) .. " +●"), "Diagnostic must follow row: " .. row .. "\n" .. text)
	end
	vim.diagnostic.set(diagnostic_ns, buf, vim.deepcopy(diagnostics))
	view = screen()
	diagnostic_after(view, "│ long text  │ x      │")
	contains(view, "│ long text  │        │\n│ long text  │        │")
	diagnostic_after(view, "│ c          │ d      │")
	contains(view, "╰────────────┴────────╯")
	unchanged()

	move(5)
	expect_rows({ 2, 3, 5 })
	view = screen()
	diagnostic_after(view, source[5])
	diagnostic_after(view, "│ c          │ d      │")
	move(1)
	expect_rows({ 2, 3, 4, 5 })
	diagnostic_after(screen(), "│ long text  │ x      │")
	equal(diagnostics, vim.tbl_map(function(diagnostic)
		return {
			lnum = diagnostic.lnum, col = diagnostic.col, end_col = diagnostic.end_col,
			message = diagnostic.message, severity = diagnostic.severity,
		}
	end, vim.diagnostic.get(buf, { namespace = diagnostic_ns })), "Rendering changed diagnostics")
	vim.diagnostic.reset(diagnostic_ns, buf)

	local parsed = tables.scan(buf)[1]
	equal(2, parsed.header_row, "Header source position")
	equal(3, parsed.delimiter_row, "Delimiter source position")
	equal({ 4, 5 }, parsed.source_rows, "Body source positions")

	-- Cursor row only is raw; widths and neighboring wrapped rows stay intact.
	move(6)
	expect_rows({ 2, 3, 4 })
	view = screen()
	contains(view, "| c | d |")
	contains(view, "│ long text  │ x      │")
	move(5)
	expect_rows({ 2, 3, 5 })
	view = screen()
	contains(view, "| long text long text long text | x |")
	contains(view, "│ c          │ d      │")
	move(3)
	expect_rows({ 3, 4, 5 })
	contains(screen(), "| A | B |")
	keys("j")
	equal(4, vim.api.nvim_win_get_cursor(0)[1], "j must reach the delimiter")
	expect_rows({ 2, 4, 5 })
	contains(screen(), "| --- | --- |")
	keys("j")
	equal(5, vim.api.nvim_win_get_cursor(0)[1], "j must reach the first body row")
	expect_rows({ 2, 3, 5 })
	keys("k")
	equal(4, vim.api.nvim_win_get_cursor(0)[1], "k must reach the delimiter")
	expect_rows({ 2, 4, 5 })
	keys("j")
	expect_rows({ 2, 3, 5 })
	unchanged()

	-- The active window determines the shared buffer's revealed row.
	local original_win = vim.api.nvim_get_current_win()
	vim.cmd("vsplit")
	local split_win = vim.api.nvim_get_current_win()
	move(6)
	expect_rows({ 2, 3, 4 })
	vim.api.nvim_set_current_win(original_win)
	expect_rows({ 2, 3, 5 })
	vim.api.nvim_win_close(split_win, true)
	unchanged()

	-- Entering/leaving editing modes uses actual editor modes and autocmds.
	for _, editing in ipairs({ { "startinsert", "i" }, { "startreplace", "R" } }) do
		vim.cmd(editing[1])
		wait_for(function() return vim.api.nvim_get_mode().mode == editing[2] end, editing[1] .. " did not start")
		expect_rows({})
		contains(screen(), source[3])
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "t", false)
		wait_for(function() return vim.api.nvim_get_mode().mode == "n" end, editing[1] .. " did not end")
		expect_rows({ 2, 3, 5 })
		unchanged()
	end

	for _, visual in ipairs({ "v", "V", "<C-v>" }) do
		keys(visual)
		expect_rows({})
		contains(screen(), source[3])
		keys("<Esc>")
		expect_rows({ 2, 3, 5 })
	end
	unchanged()

	-- A selection with both endpoints outside the table must still reveal it.
	for _, visual in ipairs({ "v", "V", "<C-v>" }) do
		move(1)
		expect_rows({ 2, 3, 4, 5 })
		keys(visual .. "7j")
		expect_rows({})
		keys("<Esc>")
		expect_rows({ 2, 3, 4, 5 })
	end

	-- Resize triggers width recomputation without rewriting text or changing wrap.
	vim.o.columns = 20
	vim.api.nvim_exec_autocmds("VimResized", {})
	wait_for(function()
		local chunks = marks()[1][4].virt_text
		local text = ""
		for _, chunk in ipairs(chunks) do text = text .. chunk[1] end
		return vim.fn.strdisplaywidth(text) == 19
	end, "Resize did not shrink column widths")
	expect_rows({ 2, 3, 4, 5 })
	contains(screen(), "│ long   │ x      │")
	unchanged()
	vim.o.columns = 80
	vim.api.nvim_exec_autocmds("VimResized", {})

	move(6)
	expect_rows({ 2, 3, 4 })
	keys("0fdrz")
	wait_for(function() return tables.scan(buf)[1].rows[2][2] == "z" end, "Edit was not parsed")
	keys("u")
	wait_for(function() return vim.deep_equal(source, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) end, "Undo did not restore the source")
	expect_rows({ 2, 3, 4 })

	-- Top-of-buffer/EOF anchors, no-body tables, and row_separator=false.
	local Renderer = require("markdown_table_renderer.renderer")
	local layout_config = { max_width_ratio = 0.95, min_col_width = 6, max_col_width = 10, priority = 250, row_separator = false }
	local function fixture(lines)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		move(1)
		tables.queue(buf, true)
		pause()
		return tables.scan(buf)
	end
	local scanned = fixture({ "| A | B |", "| --- | --- |", "| c | d |" })
	expect_rows({ 1, 2 })
	contains(screen(), "| A | B |")
	move(3)
	expect_rows({ 0, 1 })
	contains(screen(), "╭────────┬────────╮")
	contains(screen(), "| c | d |")
	Renderer.apply(buf, scanned, layout_config, vim.api.nvim_get_current_win(), function() return false end)
	view = screen()
	contains(view, "╭────────┬────────╮")
	contains(view, "│ c      │ d      │")
	contains(view, "╰────────┴────────╯")
	scanned = fixture({ "| A | B |", "| --- | --- |" })
	Renderer.apply(buf, scanned, layout_config, vim.api.nvim_get_current_win(), function() return false end)
	contains(screen(), "╰────────┴────────╯")
	vim.wo.wrap = false
	Renderer.apply(buf, scanned, layout_config, vim.api.nvim_get_current_win(), function() return false end)
	assert(not vim.wo.wrap, "Rendering changed nowrap")
	contains(screen(), "╰────────┴────────╯")
	vim.wo.wrap = true

	-- A table taller than the window stays partially rendered while traversing it.
	local long = { "| A | B |", "| --- | --- |" }
	for index = 1, 40 do long[#long + 1] = ("| row %d | value |"):format(index) end
	fixture(long)
	keys("35j")
	equal(36, vim.api.nvim_win_get_cursor(0)[1], "Long-table navigation skipped source rows")
	wait_for(function() return #rendered_rows() == #long - 1 and not vim.tbl_contains(rendered_rows(), 35) end, "Long table lost rendering on entry")
	contains(screen(), long[36])
	contains(screen(), "│ row")
	keys("<C-b>")
	local paged_row = vim.api.nvim_win_get_cursor(0)[1]
	assert(paged_row < 36, "Page-up did not scroll through the table")
	wait_for(function()
		return #rendered_rows() == #long - 1 and not vim.tbl_contains(rendered_rows(), paged_row - 1)
	end, "Page-up lost table rendering")
	contains(screen(), long[paged_row])
	equal(long, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "Long-table navigation changed source")

	-- Visual selections can touch two separate tables.
	fixture({ "| A | B |", "| --- | --- |", "| c | d |", "", "between", "", "| E | F |", "| --- | --- |", "| g | h |" })
	for _, visual in ipairs({ "v", "V", "<C-v>" }) do
		move(1)
		expect_rows({ 1, 2, 6, 7, 8 })
		keys(visual .. "8j")
		expect_rows({})
		keys("<Esc>")
		expect_rows({ 0, 1, 2, 6, 7 })
	end

	finished = true
	io.stdout:write("Markdown table renderer tests passed\n")
	vim.cmd("qa!")
end)
vim.schedule(resume)
