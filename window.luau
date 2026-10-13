-- Window half. ⇧⌘F: Tern's preset owns that chord, so a plugin default would be left
-- out; settings.json binds it instead (`"shift+cmd+f": "plugin.find-in-files.open"`,
-- written with cx.settings:bind, which validates it).

tern.command({
	id = "open",
	title = "Find in files",
	icon = "search",
	group = "Search",
	run = function(cx)
		local focused = cx.session:focused()
		local p = focused and cx.session:pane(focused)
		local cwd = if p and p.cwd and p.cwd ~= "" then p.cwd else tern.getenv("HOME") or "/"
		if not cx:new_block("find-in-files.search", { cwd }, "beside") then
			cx:toast("error", "Find in files: block failed to open")
		end
	end,
})

-- A new search block opened inside a folder that a parked search (parked by opening
-- a result) covers brings that search back instead, with its query and results.
-- The editor's cwd is the file's directory, so a root covers its subfolders.
tern.on("pane_created", function(ev, cx)
	local new = cx.session:pane(ev.pane)
	if not new or new.block ~= "find-in-files.search" or not new.cwd or new.cwd == "" then
		return
	end
	local cwd = new.cwd
	local roots = tern.kv.get("roots") or {}
	local best, best_len = nil, -1
	for _, p in cx.session:panes() do
		local root = roots[tostring(p.pane)]
		-- A live search block always has a title; a closed-while-parked husk has "".
		if p.parked and p.block == "find-in-files.search" and root and p.title ~= ""
			and (cwd == root or string.sub(cwd, 1, #root + 1) == root .. "/")
			and #root > best_len
		then
			best, best_len = p.pane, #root
		end
	end
	if best then
		cx.layout:close(ev.pane)
		cx.layout:unpark(best)
	end
end)

-- Editor pane -> the search block it was opened from, so closing the editor brings
-- the parked search back. `pane_closed` doesn't fire for file blocks, so a timer
-- watches the editors while any are open.
local origin: { [number]: number } = {}
local watching = false

local function watch(cx)
	local left = false
	for editor, search in origin do
		if not cx.session:pane(editor) then
			origin[editor] = nil
			local p = cx.session:pane(search)
			if p and p.parked then
				cx.layout:unpark(search)
			end
		else
			left = true
		end
	end
	watching = left
	if left then
		tern.timer(300, watch)
	end
end

-- Opens a result in place of its search block. "replace" doesn't swap out plugin
-- blocks, so open the file beside the block, then park the block: its split
-- collapses and the editor takes the space. The search (query + results) stays
-- alive in the session's deck until the editor closes.
local function open_in_place(cx, search: number, path: string, line: number?)
	-- "beside" is relative to the focused pane: make that the search block.
	if cx.session:pane(search) then
		cx.layout:focus(search)
	end
	local editor = cx.docs:open(path, { how = "beside", line = line })
	origin[editor] = search
	-- The open lands asynchronously; parking before it does would collapse the tab.
	local tries = 0
	local function park(cx2)
		tries += 1
		if cx2.session:tab_of(editor) or tries > 20 then
			if cx2.session:pane(search) then
				cx2.layout:park(search)
			end
			cx2.layout:focus(editor)
			if not watching then
				watching = true
				tern.timer(300, watch)
			end
			return
		end
		tern.timer(50, park)
	end
	tern.timer(50, park)
end

-- Result rows (clicks) and ⏎ (the host's cx:open) open links `file://<path>#L<line>`
-- from a search block; claim them and open the file in place of the block.
tern.route.link(function(link, cx)
	local p = cx.session:pane(link.pane)
	if not p or p.block ~= "find-in-files.search" then
		return nil
	end
	local enc, line = string.match(link.url, "^file://(/[^#]*)#L(%d+)$")
	if not enc then
		return nil
	end
	local path = string.gsub(enc, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end)
	open_in_place(cx, link.pane, path, tonumber(line))
	return { handled = true }
end)
