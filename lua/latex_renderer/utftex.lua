local M = {}

local cache = {}
local pending = {}
local requests = {}
local active_processes = 0
local max_processes = 2
local baseline_marker = vim.fn.nr2char(0xE000)

-- Return the byte after a TeX token, including balanced groups and escaped
-- braces. Unbraced script arguments can be a command or a Unicode character.
local function token_end(source, start)
	local char = source:sub(start, start)
	if char == "\\" then
		local command = source:match("^\\%a+", start)
		if command then
			return start + #command
		end
		return math.min(#source + 1, start + 2)
	elseif char == "{" then
		local depth, position = 1, start + 1
		while position <= #source do
			char = source:sub(position, position)
			if char == "\\" then
				position = token_end(source, position)
			else
				if char == "{" then depth = depth + 1 end
				if char == "}" then depth = depth - 1 end
				position = position + 1
				if depth == 0 then return position end
			end
		end
		return nil
	end
	local character = source:match("^.[\128-\191]*", start)
	return character and start + #character or nil
end

-- utftex does not support \texttt; render its contents as regular text.
local function normalize_texttt(source)
	local parts, position, previous = {}, 1, 1
	while position <= #source do
		if source:sub(position, position) == "\\" then
			local stop = token_end(source, position)
			if source:sub(position, stop - 1) == "\\texttt" then
				parts[#parts + 1] = source:sub(previous, position - 1)
				parts[#parts + 1] = "\\text"
				previous = stop
			end
			position = stop
		else
			position = position + 1
		end
	end
	parts[#parts + 1] = source:sub(previous)
	return table.concat(parts)
end

-- Call replace(operator, argument) for each top-level script and splice in its
-- result. The operator keeps any whitespace before the argument.
local function map_scripts(source, replace)
	local parts, position, previous = {}, 1, 1
	while position <= #source do
		local char = source:sub(position, position)
		if char == "\\" then
			position = token_end(source, position)
		elseif char == "_" or char == "^" then
			local argument = source:find("%S", position + 1)
			local stop = argument and token_end(source, argument)
			if stop then
				parts[#parts + 1] = source:sub(previous, position - 1)
				parts[#parts + 1] = replace(source:sub(position, argument - 1), source:sub(argument, stop - 1))
				position, previous = stop, stop
			else
				position = position + 1
			end
		else
			position = position + 1
		end
	end
	parts[#parts + 1] = source:sub(previous)
	return table.concat(parts)
end

-- Return a token's content without its enclosing braces, and the byte after it.
local function argument_at(source, start)
	start = source:find("%S", start)
	local stop = start and token_end(source, start)
	if not stop then
		return nil
	end
	local token = source:sub(start, stop - 1)
	if token:sub(1, 1) == "{" then
		token = token:sub(2, -2)
	end
	return token, stop
end

local function parenthesize(text)
	text = vim.trim(text)
	if text:match("^%w+$") or text:match("^\\%a+$") or text:match("^[\192-\255][\128-\191]*$") then
		return text
	end
	return "(" .. text .. ")"
end

local fractions = { ["\\frac"] = true, ["\\dfrac"] = true, ["\\tfrac"] = true }
local radicals = { [""] = "√", ["3"] = "∛", ["4"] = "∜" }

-- utftex always stacks fractions and roots over several rows, which cannot
-- fit inside a one-row script. Rewrite them as n/2 and √x first.
local function linearize(source)
	local parts, position, previous = {}, 1, 1
	while position <= #source do
		local command = source:match("^\\%a+", position)
		local replacement, stop
		if command and fractions[command] then
			local numerator, after = argument_at(source, position + #command)
			local denominator
			if numerator then
				denominator, stop = argument_at(source, after)
			end
			if denominator then
				replacement = parenthesize(linearize(numerator)) .. "/" .. parenthesize(linearize(denominator))
			end
		elseif command == "\\sqrt" then
			local index, after = source:match("^%s*%[([^%]]*)%]()", position + #command)
			local radical = radicals[vim.trim(index or "")]
			local radicand
			if radical then
				radicand, stop = argument_at(source, after or position + #command)
			end
			if radicand then
				replacement = radical .. parenthesize(linearize(radicand))
			end
		end
		if replacement then
			parts[#parts + 1] = source:sub(previous, position - 1)
			parts[#parts + 1] = replacement
			position, previous = stop, stop
		elseif command then
			position = position + #command
		else
			-- Step into groups so nested fractions and roots are rewritten too.
			position = position + (source:sub(position, position) == "\\" and 2 or 1)
		end
	end
	parts[#parts + 1] = source:sub(previous)
	return table.concat(parts)
end

-- Plan a conversion where script operators and braces stay literal while
-- commands in their arguments become Unicode. Argument contents with commands
-- are converted by utftex before the main layout, so each script's exact
-- width is known when it is shielded. A script whose content does not convert
-- to a single row keeps its raw source.
local function plan_conversion(source)
	-- utftex treats U+E000..U+E757 as wide; use its single-cell PUA range.
	local next_code = 0xE800
	local function next_marker()
		local marker
		repeat
			marker = vim.fn.nr2char(next_code)
			next_code = next_code + 1
		until not source:find(marker, 1, true)
		return marker
	end

	local pieces, registered = {}, {}
	local function parse_script(operator, argument)
		local braced = argument:sub(1, 1) == "{"
		local node = {
			operator = operator,
			braced = braced,
			content = braced and argument:sub(2, -2) or argument,
			nested = {},
		}
		-- Nested scripts are rendered separately, so stand-ins keep them
		-- literal while the surrounding content converts.
		node.prepared = map_scripts(node.content, function(nested_operator, nested_argument)
			local marker = next_marker()
			node.nested[marker] = parse_script(nested_operator, nested_argument)
			return "\\text{" .. marker .. "}"
		end)
		local commands = map_scripts(node.content, function() return "" end)
		if commands:find("\\", 1, true) then
			node.piece = linearize(node.prepared)
			if not registered[node.piece] then
				registered[node.piece] = true
				pieces[#pieces + 1] = node.piece
			end
		end
		return node
	end

	local scripts = {}
	map_scripts(source, function(operator, argument)
		scripts[#scripts + 1] = parse_script(operator, argument)
		return ""
	end)

	local function script_text(node, results)
		local body
		if not node.piece then
			body = node.prepared
			for marker, child in pairs(node.nested) do
				body = body:gsub("\\text{" .. marker .. "}", function() return script_text(child, results) end)
			end
		elseif results[node.piece] then
			body = results[node.piece]
			for marker, child in pairs(node.nested) do
				body = body:gsub(marker, function() return script_text(child, results) end)
			end
		else
			body = node.content
		end
		return node.operator .. (node.braced and "{" .. body .. "}" or body)
	end

	-- Return the source with each script shielded, and the shield characters.
	local function assemble(results)
		local replacements, markers = {}, {}
		local function literal(script)
			-- Source line breaks and tabs are inline whitespace, not layout rows.
			script = script:gsub("%s", " ")
			-- Shield each ASCII character with a one-cell private-use character.
			-- This preserves both exact notation and width during utftex layout.
			local encoded = script:gsub("[%z\1-\127]", function(char)
				if not markers[char] then
					markers[char] = next_marker()
					replacements[markers[char]] = char
				end
				return markers[char]
			end)
			return "\\text{" .. encoded .. "}"
		end
		local index = 0
		local protected = map_scripts(source, function()
			index = index + 1
			return literal(script_text(scripts[index], results))
		end)
		return protected, replacements
	end

	return { pieces = pieces, separator = #pieces > 0 and next_marker() or nil, assemble = assemble }
end

local function executable()
	local path = vim.fn.exepath("utftex")
	return path ~= "" and path or nil
end

local function has_subscribers(job)
	for _, subscriber in ipairs(job.subscribers) do
		if subscriber.active then
			return true
		end
	end
	return false
end

local function subscribe(job, callback)
	local subscriber = { active = true, callback = callback }
	job.subscribers[#job.subscribers + 1] = subscriber
	return function()
		if not subscriber.active then
			return
		end
		subscriber.active = false
		if not has_subscribers(job) then
			job.accepting = false
			for process in pairs(job.processes) do
				pcall(process.kill, process, "sigterm")
			end
		end
	end
end

local function finish(job, converted, err)
	if pending[job.source] == job then
		pending[job.source] = nil
	end
	if converted then
		cache[job.source] = converted
	end
	local callbacks = {}
	for _, subscriber in ipairs(job.subscribers) do
		if subscriber.active then
			callbacks[#callbacks + 1] = subscriber.callback
		end
	end
	vim.schedule(function()
		for _, callback in ipairs(callbacks) do
			callback(converted, err)
		end
	end)
end

-- Limit processes, rather than whole conversions: failed script batches may
-- fan out into several retries, and those must share the same limit.
local function run_next()
	while active_processes < max_processes and #requests > 0 do
		local request = table.remove(requests, 1)
		local job = request.job
		local process
		active_processes = active_processes + 1
		local function complete(result)
			vim.schedule(function()
				if process then
					job.processes[process] = nil
				end
				active_processes = active_processes - 1
				request.on_exit(result)
				run_next()
			end)
		end
		if not job.accepting then
			complete({ code = 1, stderr = "conversion cancelled" })
		else
			local ok, result = pcall(vim.system, request.args, {
				stdin = request.stdin,
				text = true,
				timeout = 15000,
			}, complete)
			if ok then
				process = result
				job.processes[process] = true
			else
				complete({ code = 1, stderr = "could not start utftex: " .. tostring(result) })
			end
		end
	end
end

-- Queue every utftex call, including script preprocessing and retries.
-- on_exit runs on the main loop, so it may call any Neovim API.
local function run(job, args, stdin, on_exit)
	requests[#requests + 1] = { job = job, args = args, stdin = stdin, on_exit = on_exit }
	run_next()
end

-- Convert script contents in one utftex call, keyed by piece. A piece maps to
-- nil unless it converts cleanly to a single non-empty row. utftex reports
-- errors for the whole call, so a failed batch retries each piece alone.
local function convert_pieces(job, command, pieces, separator, callback)
	if not job.accepting then
		callback({})
		return
	end
	local args = { command }
	for index, piece in ipairs(pieces) do
		if index > 1 then
			args[#args + 1] = "\\text{" .. separator .. "}"
		end
		-- A leading empty group keeps a piece such as -x from parsing as options.
		args[#args + 1] = "{}" .. piece
	end
	run(job, args, nil, function(result)
		local results = {}
		if result.code == 0 then
			local stdout = (result.stdout or ""):gsub("\r\n", "\n"):gsub("\n$", "")
			local outputs = { {} }
			for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
				if vim.trim(line) == separator then
					outputs[#outputs + 1] = {}
				else
					table.insert(outputs[#outputs], line)
				end
			end
			if #outputs == #pieces then
				for index, rows in ipairs(outputs) do
					local row = #rows == 1 and vim.trim(rows[1]) or ""
					results[pieces[index]] = row ~= "" and row or nil
				end
			end
		elseif #pieces > 1 and job.accepting then
			local remaining = #pieces
			for _, piece in ipairs(pieces) do
				convert_pieces(job, command, { piece }, separator, function(single)
					results[piece] = single[piece]
					remaining = remaining - 1
					if remaining == 0 then
						callback(results)
					end
				end)
			end
			return
		end
		callback(results)
	end)
end

local function parse_output(stdout)
	local output = stdout:gsub("\r\n", "\n"):gsub("\n+$", "")
	local marker_start = output:find(baseline_marker, 1, true)
	if not marker_start then
		return nil
	end

	local prefix = output:sub(1, marker_start - 1)
	local baseline = select(2, prefix:gsub("\n", "")) + 1
	prefix = prefix:gsub("[ \t]+$", "")
	output = (prefix .. output:sub(marker_start + #baseline_marker)):gsub("\n+$", "")
	if output == "" then
		return nil
	end
	return { output = output, baseline = baseline }
end

local function error_message(result)
	local message = vim.trim(result.stderr or "")
	if message == "" then
		message = vim.trim(result.stdout or "")
	end
	message = vim.split(message, "\n", { plain = true })[1] or ""
	message = message:gsub("^ERROR:%s*", "")
	if #message > 200 then
		message = message:sub(1, 197) .. "..."
	end
	return message == "" and "utftex failed" or "utftex: " .. message
end

function M.available()
	return executable() ~= nil
end

function M.convert(source, callback)
	local cached = cache[source]
	if cached then
		vim.schedule(function()
			callback(cached)
		end)
		return function() end
	end

	local command = executable()
	if not command then
		vim.schedule(function()
			callback(nil, "latex-renderer requires utftex for inline math")
		end)
		return function() end
	end

	local existing = pending[source]
	if existing and existing.accepting then
		return subscribe(existing, callback)
	end

	local job = {
		accepting = true,
		processes = {},
		source = source,
		subscribers = {},
	}
	pending[source] = job
	local cancel = subscribe(job, callback)
	local plan = plan_conversion(normalize_texttt(source))
	local function render(results)
		if not job.accepting then
			finish(job, nil, "conversion cancelled")
			return
		end
		local protected_source, replacements = plan.assemble(results)
		local marked_source = protected_source .. "\\text{" .. baseline_marker .. "}"
		run(job, { command }, marked_source, function(result)
			if result.code ~= 0 then
				finish(job, nil, error_message(result))
				return
			end
			local converted = parse_output(result.stdout or "")
			if not converted then
				finish(job, nil, "utftex did not return a usable baseline marker")
				return
			end
			for marker, char in pairs(replacements) do
				converted.output = converted.output:gsub(marker, function() return char end)
			end
			finish(job, converted)
		end)
	end
	if #plan.pieces == 0 then
		render({})
	else
		convert_pieces(job, command, plan.pieces, plan.separator, render)
	end
	return cancel
end

return M
