local M = {}

local cache = {}
local pending = {}
local baseline_marker = vim.fn.nr2char(0xE000)

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
			if job.process then
				pcall(job.process.kill, job.process, "sigterm")
			end
		end
	end
end

local function finish(job, converted, err)
	if pending[job.source] == job then
		pending[job.source] = nil
	end
	job.process = nil
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
		source = source,
		subscribers = {},
	}
	pending[source] = job
	local cancel = subscribe(job, callback)
	local marked_source = source .. "\\text{" .. baseline_marker .. "}"
	job.process = vim.system({ command }, { stdin = marked_source, text = true, timeout = 15000 }, function(result)
		if result.code ~= 0 then
			finish(job, nil, error_message(result))
			return
		end
		local converted = parse_output(result.stdout or "")
		if not converted then
			finish(job, nil, "utftex did not return a usable baseline marker")
			return
		end
		finish(job, converted)
	end)
	return cancel
end

return M
