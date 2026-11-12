-- Run with: nvim --headless -u NONE -i NONE -l tests/latex_utftex_queue.lua
-- Uses controlled subprocess completions; utftex is not required.
vim.defer_fn(function()
	io.stderr:write("Inline conversion queue tests timed out\n")
	vim.cmd("cquit 1")
end, 20000)
local original_system, original_exepath = vim.system, vim.fn.exepath
local ok, err = xpcall(function()
	vim.opt.runtimepath:prepend(vim.fn.getcwd())
	local marker = vim.fn.nr2char(0xE000)
	vim.fn.exepath = function(name)
		return name == "utftex" and "/fake/utftex" or original_exepath(name)
	end

	local function fixture(respond, fail_spawn)
		local held, started, peak, live, kills = {}, 0, 0, 0, 0
		vim.system = function(args, opts, callback)
			started = started + 1
			if fail_spawn and fail_spawn(args, opts) then
				error("EMFILE: too many open files")
			end
			live = live + 1
			peak = math.max(peak, live)
			assert(live <= 2, "More than two utftex processes ran concurrently")
			local process = {}
			function process:kill()
				self.killed = true
				kills = kills + 1
			end
			held[#held + 1] = { args = args, opts = opts, callback = callback, process = process }
			return process
		end
		package.loaded["latex_renderer.utftex"] = nil
		local converter = require("latex_renderer.utftex")
		local function flush()
			local done = false
			vim.schedule(function() done = true end)
			assert(vim.wait(1000, function() return done end), "Main loop did not advance")
		end
		local function drain(done)
			for _ = 1, 1000 do
				if #held > 0 then
					local request = table.remove(held, 1)
					live = live - 1
					local result
					if request.process.killed then
						result = { code = 143, stderr = "cancelled" }
					elseif respond then
						result = respond(request)
					else
						local stdout = request.opts.stdin:gsub("\\text{" .. marker .. "}$", marker)
						result = { code = 0, stdout = stdout .. "\n" }
					end
					request.callback(result)
				end
				flush()
				if #held == 0 and done() then
					assert(live == 0, "Processes remained after draining")
					return
				end
			end
			error("Queue did not drain")
		end
		return converter, drain, function() return started, peak, kills end, flush
	end

	-- A large burst must queue rather than exhaust subprocess descriptors.
	local converter, drain, stats = fixture()
	local completed = 0
	for index = 1, 100 do
		local source = "burst" .. index
		converter.convert(source, function(result, failure)
			assert(result, failure)
			assert(result.output == source, "Queued conversion returned the wrong formula")
			completed = completed + 1
		end)
	end
	assert(stats() == 2, "Burst was not held in the queue")
	drain(function() return completed == 100 end)
	local started, peak = stats()
	assert(started == 100 and peak == 2, "Burst did not use bounded parallelism")

	-- Failed preprocessing batches fan out into retries, still under the cap.
	local batches, singles, renders = 0, 0, 0
	converter, drain, stats = fixture(function(request)
		if request.opts.stdin then
			renders = renders + 1
			return { code = 0, stdout = "rendered" .. marker .. "\n" }
		elseif #request.args > 2 then
			batches = batches + 1
			return { code = 1, stderr = "unsupported command" }
		end
		singles = singles + 1
		return { code = 0, stdout = "alpha\n" }
	end)
	completed = 0
	for index = 1, 8 do
		converter.convert(index .. [[x_{\alpha}+y_{\beta}+z_{\gamma}]], function(result, failure)
			assert(result, failure)
			completed = completed + 1
		end)
	end
	drain(function() return completed == 8 end)
	assert(batches == 8 and singles == 24 and renders == 8, "Script retries or final renders were lost")

	-- Cancellation skips queued work, stops running work, and permits a new
	-- subscription to the same source without disturbing the replacement job.
	converter, drain, stats = fixture()
	completed = 0
	local function success(result, failure)
		assert(result, failure)
		completed = completed + 1
	end
	local function cancelled()
		error("Cancelled subscriber received a result")
	end
	local cancel_active = converter.convert("active", cancelled)
	converter.convert("other", success)
	local cancel_queued = converter.convert("queued", cancelled)
	converter.convert("survivor", success)
	cancel_queued()
	cancel_active()
	cancel_active() -- Cancellation is idempotent.
	converter.convert("queued", success)
	drain(function() return completed == 3 end)
	local kills
	started, peak, kills = stats()
	assert(started == 4 and kills == 1, "Cancellation spawned queued work or failed to kill active work")
	converter.convert("survivor", success)
	drain(function() return completed == 4 end)
	assert(stats() == started, "Cached conversion spawned a process")

	-- Shared conversions remain alive until their final subscriber cancels.
	converter, drain, stats = fixture()
	completed = 0
	local cancel_shared = converter.convert("shared", cancelled)
	converter.convert("shared", success)
	cancel_shared()
	drain(function() return completed == 1 end)
	started, peak, kills = stats()
	assert(started == 1 and kills == 0, "Cancelling one subscriber stopped shared work")

	-- A synchronous spawn exception is reported and releases its queue slot.
	local failed_once = false
	converter, drain, stats = fixture(nil, function(_, opts)
		if opts.stdin:find("spawnfailure", 1, true) and not failed_once then
			failed_once = true
			return true
		end
		return false
	end)
	completed = 0
	local failures = 0
	converter.convert("spawnfailure", function(result, failure)
		assert(not result and failure:find("EMFILE", 1, true), "Spawn failure was not reported")
		failures = failures + 1
	end)
	for index = 1, 6 do
		converter.convert("recovery" .. index, success)
	end
	drain(function() return completed == 6 and failures == 1 end)
	-- The failed source must not stay stuck in the pending-conversion map.
	converter.convert("spawnfailure", success)
	drain(function() return completed == 7 end)

	io.stdout:write("Inline conversion queue tests passed\n")
end, debug.traceback)
vim.system, vim.fn.exepath = original_system, original_exepath
if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
else
	vim.cmd("qa!")
end
