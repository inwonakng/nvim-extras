-- Run with: nvim --headless -u NONE -i NONE -l tests/latex_inline.lua
-- No Tree-sitter parsers or external converters are required.
local ok, err = xpcall(function()
	vim.opt.runtimepath:prepend(vim.fn.getcwd())
	vim.bo.tabstop = 8
	local inline = require("latex_renderer.inline")
	local namespace = vim.api.nvim_create_namespace("latex-renderer-inline")
	local buf = vim.api.nvim_get_current_buf()
	local function equal(expected, actual, message)
		assert(vim.deep_equal(expected, actual), message .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
	end
	local function layout(source, formulas, focused)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { source })
		local entries = {}
		local position = 1
		for _, formula in ipairs(formulas) do
			local first, last = source:find("%$.-%$", position)
			assert(first, "Missing formula in fixture")
			position = last + 1
			entries[#entries + 1] = {
				item = { start_row = 0, end_row = 0, start_col = first - 1, end_col = last },
				output = formula[1],
				baseline = formula[2],
			}
		end
		inline.apply(buf, entries, focused or function() return false end)
		local above, below, baselines = {}, {}, {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
			local details = mark[4]
			if details.virt_lines then
				local lines = details.virt_lines_above and above or below
				for _, chunks in ipairs(details.virt_lines) do
					lines[#lines + 1] = chunks[1][1]
				end
			elseif details.virt_text then
				baselines[#baselines + 1] = details.virt_text[1][1]
			end
		end
		equal({ source }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "Rendering changed the source")
		return above, below, baselines
	end

	-- Real utftex output for the reported line: earlier replacements shorten
	-- the baseline, so the second root's roof must move left with its radical.
	local above, below, baselines = layout(
		[=[- $(1/\sqrt{2},1/\sqrt{2})$ gives $u=(x_1+x_2)/\sqrt{2}$.]=],
		{
			{ "    ┌─┐    ┌─┐\n(1/╲│2 ,1/╲│2 )", 2 },
			{ "           ┌─┐\nu=(x₁+x₂)/╲│2", 2 },
		}
	)
	equal({ "  " .. "    ┌─┐    ┌─┐" .. string.rep(" ", 8) .. "           ┌─┐" }, above, "Root roofs must follow rendered columns")
	equal({}, below, "Roots should have no lower lines")
	equal({ "(1/╲│2 ,1/╲│2 )", "u=(x₁+x₂)/╲│2 " }, baselines, "Baselines must reserve the full formula width")

	-- Adjacent formulas need no artificial gap. A short baseline reserves its
	-- widest row, keeping the following formula aligned both above and below.
	above, below, baselines = layout("$a$$b$", { { "1234\n─\n2", 2 }, { "X\nY", 1 } })
	equal({ "1234 " }, above, "Adjacent formulas gained a gap")
	equal({ "2   Y" }, below, "Lower lines lost their baseline alignment")
	equal({ "─   ", "X" }, baselines, "Wide upper rows must not overlap following formulas")

	-- Tabs after a replacement expand from the rendered column, not the
	-- original byte offset. Unicode prose is measured in display cells.
	above, below = layout("é界\t$a$\t$b$", { { "A", 1 }, { "b\n─\nc", 2 } })
	equal({ string.rep(" ", 16) .. "b" }, above, "Tab-expanded upper line is misaligned")
	equal({ string.rep(" ", 16) .. "c" }, below, "Tab-expanded lower line is misaligned")

	-- A revealed formula remains source, so its original width still counts.
	above = layout("$a$ $b$", { { "A", 1 }, { "b\n─", 2 } }, function(item) return item.start_col == 0 end)
	equal({ "    b" }, above, "Revealed source width must be retained")

	inline.clear(buf)
	equal({}, vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}), "Clear left decorations behind")
	io.stdout:write("Inline math layout tests passed\n")
end, debug.traceback)
if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
