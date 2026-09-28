local M = {}

local cache_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "latex-renderer")
local pending = {}
local jobs = {}
local active_jobs = 0
local max_jobs = 2
local template_version = "2"
local next_job_id = 0
local run_next

local function executable(name)
	local path = vim.fn.exepath(name)
	return path ~= "" and path or nil
end

local function write_file(path, content)
	local file, err = io.open(path, "w")
	if not file then
		return false, err
	end
	file:write(content)
	file:close()
	return true
end

local function document(source, color)
	local prefix = ([[
\documentclass[preview,border=2pt,varwidth,12pt]{standalone}
\usepackage{xcolor,amsmath,amssymb,amsfonts,amscd,mathtools}
\begin{document}
{\Large\color[HTML]{%s}
]]):format(color)
	local suffix = [[
}
\end{document}
]]
	local _, prefix_newlines = prefix:gsub("\n", "\n")
	return prefix .. source .. "\n" .. suffix, prefix_newlines + 1
end

local function latex_error_message(job, output)
	local lines = vim.split(output or "", "\n", { plain = true })
	local message
	local message_index
	for index, line in ipairs(lines) do
		local candidate = line:match("^!%s+(.+)")
		if candidate and not candidate:match("^==>") then
			message = candidate
			message_index = index
			break
		end
	end

	message = message or "pdflatex failed"
	local tex_line
	if message_index then
		for index = message_index + 1, math.min(#lines, message_index + 12) do
			tex_line = tonumber(lines[index]:match("^l%.(%d+)"))
			if tex_line then
				break
			end
		end
	end

	local details = { message }
	if tex_line then
		local source_line = tex_line - job.source_start_line + 1
		local source_lines = vim.split(job.source, "\n", { plain = true })
		local context = source_lines[source_line]
		if context then
			context = vim.trim(context)
			if #context > 160 then
				context = context:sub(1, 157) .. "..."
			end
			details[#details + 1] = ("Equation line %d: %s"):format(source_line, context)
		end
	end
	details[#details + 1] = "Log: " .. vim.fn.fnamemodify(job.log_path, ":~")
	return table.concat(details, "\n")
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

local function complete(job, result, err, preserved_paths)
	if job.completed then
		return
	end
	job.completed = true
	if pending[job.key] == job then
		pending[job.key] = nil
	end
	if job.started then
		active_jobs = math.max(0, active_jobs - 1)
	end
	job.process = nil
	for _, path in ipairs(job.temporary_paths) do
		if not preserved_paths or not preserved_paths[path] then
			pcall(vim.uv.fs_unlink, path)
		end
	end
	run_next()
	local callbacks = {}
	for _, subscriber in ipairs(job.subscribers) do
		if subscriber.active then
			callbacks[#callbacks + 1] = subscriber.callback
		end
	end
	vim.schedule(function()
		for _, callback in ipairs(callbacks) do
			callback(result, err)
		end
	end)
end

local function spawn(job, command, opts, callback)
	if not has_subscribers(job) then
		complete(job, nil, "cancelled")
		return
	end
	job.process = vim.system(command, opts, function(result)
		job.process = nil
		callback(result)
	end)
end

local function inspect_png(job, path, callback)
	spawn(job, { job.magick, "identify", "-format", "%w %h", path }, { text = true, timeout = 15000 }, function(result)
		if result.code ~= 0 then
			callback(nil, vim.trim(result.stderr or "ImageMagick could not inspect the rendered equation"))
			return
		end
		local width, height = (result.stdout or ""):match("(%d+)%s+(%d+)")
		if not width or not height then
			callback(nil, "ImageMagick returned invalid equation dimensions")
			return
		end
		callback({ width_px = tonumber(width), height_px = tonumber(height) })
	end)
end

local function run_job(job)
	local function render_source()
		local ok, err = write_file(job.tex_path, job.tex)
		if not ok then
			complete(job, nil, "could not write TeX source: " .. tostring(err))
			return
		end

		spawn(job, {
			job.pdflatex,
			"-interaction=nonstopmode",
			"-halt-on-error",
			"-no-shell-escape",
			"-output-directory=" .. cache_dir,
			job.tex_path,
		}, { cwd = cache_dir, text = true, timeout = 15000 }, function(latex_result)
			if latex_result.code ~= 0 then
				local output = table.concat({ latex_result.stderr or "", latex_result.stdout or "" }, "\n")
				local preserved_paths = {
					[job.tex_path] = true,
					[job.log_path] = true,
				}
				complete(job, nil, latex_error_message(job, output), preserved_paths)
				return
			end
			pcall(vim.uv.fs_unlink, job.temp_png_path)
			spawn(job, {
				job.magick,
				"-density",
				"192",
				job.pdf_path .. "[0]",
				"-background",
				"none",
				"-alpha",
				"on",
				"-trim",
				job.temp_png_path,
			}, { text = true, timeout = 15000 }, function(convert_result)
				if convert_result.code ~= 0 then
					pcall(vim.uv.fs_unlink, job.temp_png_path)
					complete(
						job,
						nil,
						vim.trim(convert_result.stderr or "ImageMagick could not convert the equation")
					)
					return
				end
				inspect_png(job, job.temp_png_path, function(meta, inspect_error)
					if not meta then
						pcall(vim.uv.fs_unlink, job.temp_png_path)
						complete(job, nil, inspect_error)
						return
					end
					local renamed, rename_error = vim.uv.fs_rename(job.temp_png_path, job.png_path)
					if not renamed then
						complete(job, nil, "could not cache rendered equation: " .. tostring(rename_error))
						return
					end
					meta.path = job.png_path
					complete(job, meta)
				end)
			end)
		end)
	end

	if vim.fn.filereadable(job.png_path) == 1 then
		inspect_png(job, job.png_path, function(meta)
			if meta then
				meta.path = job.png_path
				complete(job, meta)
				return
			end
			pcall(vim.uv.fs_unlink, job.png_path)
			render_source()
		end)
	else
		render_source()
	end
end

run_next = function()
	while active_jobs < max_jobs and #jobs > 0 do
		local job = table.remove(jobs, 1)
		if pending[job.key] == job and has_subscribers(job) then
			active_jobs = active_jobs + 1
			job.started = true
			run_job(job)
		elseif pending[job.key] == job then
			pending[job.key] = nil
		end
	end
end

local function enqueue(job)
	jobs[#jobs + 1] = job
	run_next()
end

function M.available()
	return executable("pdflatex") ~= nil and executable("magick") ~= nil
end

function M.compile(source, color, callback)
	local pdflatex = executable("pdflatex")
	local magick = executable("magick")
	if not pdflatex or not magick then
		vim.schedule(function()
			callback(nil, "latex-renderer requires pdflatex and ImageMagick")
		end)
		return function() end
	end

	vim.fn.mkdir(cache_dir, "p")
	local key = vim.fn.sha256(table.concat({ template_version, color, source }, "\0"))
	local existing = pending[key]
	if existing and existing.accepting then
		return subscribe(existing, callback)
	end

	next_job_id = next_job_id + 1
	local basename = ("%s.%d.%d"):format(key, vim.fn.getpid(), next_job_id)
	local tex_path = vim.fs.joinpath(cache_dir, basename .. ".tex")
	local pdf_path = vim.fs.joinpath(cache_dir, basename .. ".pdf")
	local temp_png_path = vim.fs.joinpath(cache_dir, basename .. ".png")
	local log_path = vim.fs.joinpath(cache_dir, basename .. ".log")
	local tex, source_start_line = document(source, color)
	local job = {
		accepting = true,
		key = key,
		source = source,
		source_start_line = source_start_line,
		tex = tex,
		tex_path = tex_path,
		log_path = log_path,
		pdf_path = pdf_path,
		png_path = vim.fs.joinpath(cache_dir, key .. ".png"),
		temp_png_path = temp_png_path,
		temporary_paths = {
			tex_path,
			pdf_path,
			vim.fs.joinpath(cache_dir, basename .. ".aux"),
			log_path,
			temp_png_path,
		},
		pdflatex = pdflatex,
		magick = magick,
		subscribers = {},
	}
	pending[key] = job
	local cancel = subscribe(job, callback)
	enqueue(job)
	return cancel
end

function M.cache_dir()
	return cache_dir
end

return M
