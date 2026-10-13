-- Host half: the "Find in files" block.
--
-- Type to search (ripgrep, smart case, literal by default). Results update as you type.
--   up/down        move the selection
--   enter / click  open the selected match at its line, in place of this block
--   ctrl+r         toggle regex
--   ctrl+i         toggle case-sensitive (default: smart case)
--   ctrl+u         clear the query
--   esc            close the block

local RG = "/opt/homebrew/bin/rg"
local DEBOUNCE_MS = 120
local MAX_RESULTS = 1000
local MAX_PER_FILE = 200

type Match = { path: string, line: number, col: number, text: string }

type State = {
	cwd: string,
	query: string,
	regex: boolean,
	case: boolean,
	results: { Match },
	files: number,
	truncated: boolean,
	selected: number,
	status: string,
	searching: boolean,
	gen: number,
	timer: any,
	cx: any,
}

local function rg_path(): string
	if tern.fs.exists(RG) then
		return RG
	end
	if tern.fs.exists("/usr/local/bin/rg") then
		return "/usr/local/bin/rg"
	end
	return "rg"
end

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""))
end

local function parse(stdout: string): ({ Match }, number, boolean)
	local out: { Match } = {}
	local seen: { [string]: boolean } = {}
	local files = 0
	for raw in string.gmatch(stdout, "[^\n]+") do
		if #out >= MAX_RESULTS then
			return out, files, true
		end
		local path, line, col, text = string.match(raw, "^(.-):(%d+):(%d+):(.*)$")
		if path then
			if string.sub(path, 1, 2) == "./" then
				path = string.sub(path, 3)
			end
			if not seen[path] then
				seen[path] = true
				files += 1
			end
			table.insert(out, { path = path, line = tonumber(line) :: number, col = tonumber(col) :: number, text = text })
		end
	end
	return out, files, false
end

local function search(state: State)
	state.gen += 1
	local gen = state.gen
	if state.query == "" then
		state.results, state.files, state.truncated = {}, 0, false
		state.selected, state.status, state.searching = 1, "", false
		state.cx:render()
		return
	end
	local argv = {
		rg_path(), "--line-number", "--column", "--no-heading", "--color", "never",
		"--max-count", tostring(MAX_PER_FILE), "--max-columns", "300", "--max-columns-preview",
	}
	table.insert(argv, if state.case then "--case-sensitive" else "--smart-case")
	if not state.regex then
		table.insert(argv, "--fixed-strings")
	end
	table.insert(argv, "--")
	table.insert(argv, state.query)
	table.insert(argv, ".")
	state.searching = true
	state.cx:render()
	local started = tern.now()
	tern.process.run(argv, { cwd = state.cwd, timeout_ms = 15000 }, function(res)
		if gen ~= state.gen then
			return -- a newer query superseded this one
		end
		state.searching = false
		if res.status == 1 then
			state.results, state.files, state.truncated = {}, 0, false
			state.status = "No results"
		elseif res.status ~= 0 then
			state.results, state.files, state.truncated = {}, 0, false
			state.status = if res.timed_out then "Search timed out" else trim(res.stderr)
		else
			state.results, state.files, state.truncated = parse(res.stdout)
			state.status = string.format(
				"%s%d result%s in %d file%s · %d ms",
				if state.truncated then "first " else "",
				#state.results, if #state.results == 1 then "" else "s",
				state.files, if state.files == 1 then "" else "s",
				math.floor(tern.now() - started)
			)
		end
		state.selected = 1
		state.cx:render()
	end)
end

local function schedule(state: State)
	if state.timer then
		state.timer:cancel()
	end
	state.timer = tern.timer(DEBOUNCE_MS, function()
		state.timer = nil
		search(state)
	end)
end

-- `file://<path>#L<line>`: the link the window half's route.link opens in place of
-- this block (instead of a new split).
local function href(state: State, m: Match): string
	local abs = if string.sub(m.path, 1, 1) == "/" then m.path else state.cwd .. "/" .. m.path
	local enc = string.gsub(abs, "[ %%#?]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return "file://" .. enc .. "#L" .. m.line
end

local function open_match(state: State, i: number)
	local m = state.results[i]
	if m then
		state.cx:open(href(state, m))
	end
end

local function header(state: State)
	local ui = tern.ui
	local caret = if state.query == "" then ui.span("Search…", "muted") else ui.span(state.query, "strong")
	return ui.col({
		ui.row({
			ui.text({ ui.span("⌕ ", "muted"), caret, ui.span("▏", "accent") }),
			ui.badge(if state.regex then ".* regex" else "literal", if state.regex then "accent" else "muted"),
			ui.badge(if state.case then "Aa case" else "smart case", if state.case then "accent" else "muted"),
		}),
		ui.text({ ui.span(state.cwd, "muted") }),
		ui.text({
			ui.span(if state.searching then "Searching…" else state.status, "muted"),
		}),
	})
end

local function results_view(state: State, cx)
	local ui = tern.ui
	local items = {}
	local last_path: string? = nil
	-- Flat list: each match carries its file + line; consecutive matches in one file
	-- show the path only on the first so files read as groups. The text and path are
	-- links `file://<path>#L<line>`; the window half's route.link opens them in place.
	for _, m in state.results do
		local link = href(state, m)
		local detail = if m.path ~= last_path then ui.link(m.path, link, "path") else ui.span("", "muted")
		last_path = m.path
		table.insert(items, {
			label = { ui.span(string.format("%5d  ", m.line), "muted"), ui.link(trim(m.text), link) },
			detail = detail,
		})
	end
	local list = ui.list(items)
	list.p = list.p or {}
	list.p.key = "results"
	list.p.selected = state.selected - 1
	list.p.max = { lines = math.max(cx.rows - 6, 5) }
	return list
end

tern.block.define("search", {
	init = function(cx, args, saved)
		local state: State = {
			cwd = args[1] or cx.cwd or tern.getenv("HOME") or "/",
			query = "",
			regex = false,
			case = false,
			results = {},
			files = 0,
			truncated = false,
			selected = 1,
			status = "",
			searching = false,
			gen = 0,
			timer = nil,
			cx = cx,
		}
		if type(saved) == "table" then
			state.cwd = saved.cwd or state.cwd
			state.query = saved.query or ""
			state.regex = saved.regex == true
			state.case = saved.case == true
			if state.query ~= "" then
				schedule(state)
			end
		end
		-- Lets the window command find this block's folder when it's parked.
		local roots = tern.kv.get("roots") or {}
		roots[tostring(cx.pane)] = state.cwd
		tern.kv.set("roots", roots)
		return state
	end,

	title = function(state)
		if state.query == "" then
			return "Find in files"
		end
		return "Find: " .. state.query
	end,

	view = function(state, cx)
		state.cx = cx
		local ui = tern.ui
		return {
			main = ui.col({ header(state), ui.rule(""), results_view(state, cx) }),
			dock = ui.col({
				ui.text({
					ui.span("↑↓", "key"), " select  ", ui.span("⏎", "key"), " open  ",
					ui.span("⌃R", "key"), " regex  ", ui.span("⌃I", "key"), " case  ",
					ui.span("⌃U", "key"), " clear  ", ui.span("esc", "key"), " close",
				}),
			}),
		}
	end,

	key = function(state, key, cx)
		state.cx = cx
		local n = key.name
		if n == "escape" then
			cx:exit(0)
			return true
		elseif n == "up" then
			state.selected = math.max(1, state.selected - 1)
		elseif n == "down" then
			state.selected = math.min(math.max(#state.results, 1), state.selected + 1)
		elseif n == "page_up" then
			state.selected = math.max(1, state.selected - 20)
		elseif n == "page_down" then
			state.selected = math.min(math.max(#state.results, 1), state.selected + 20)
		elseif n == "enter" then
			open_match(state, state.selected)
			return false
		elseif key.ctrl and n == "r" then
			state.regex = not state.regex
			schedule(state)
		elseif key.ctrl and n == "i" then
			state.case = not state.case
			schedule(state)
		elseif key.ctrl and n == "u" then
			state.query = ""
			schedule(state)
		elseif n == "backspace" then
			if key.alt or key.meta then
				state.query = ""
			else
				local last = utf8.offset(state.query, -1)
				state.query = if last then string.sub(state.query, 1, last - 1) else ""
			end
			schedule(state)
		elseif n == "paste" and key.text then
			state.query ..= (string.gsub(key.text :: string, "[\r\n]+", " "))
			schedule(state)
		elseif key.text and not key.ctrl and not key.meta then
			state.query ..= key.text :: string
			schedule(state)
		else
			return false
		end
		return true
	end,

	save = function(state)
		return { cwd = state.cwd, query = state.query, regex = state.regex, case = state.case }
	end,
})
