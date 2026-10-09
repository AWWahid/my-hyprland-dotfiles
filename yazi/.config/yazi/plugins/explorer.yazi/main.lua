--- @since 26.8.15
-- File-explorer behaviour on top of yazi: the Quick Access start folder (built by
-- quick-access.sh), a Trash-aware Delete, the right-click menu and a Finder-style status bar.
-- Entry: `plugin explorer -- open|openwith|delete|up|menu [item|empty x y]|home|copy|cut|paste|copypath|terminal`; also previews the Trash entry.

local M = {}

local HOME = os.getenv("HOME")
local QA = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi/quick-access"
local TRASH = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi/trash-shortcut"
local BUILD = HOME .. "/.config/yazi/quick-access.sh"
local HOME_TRASH = (os.getenv("XDG_DATA_HOME") or HOME .. "/.local/share") .. "/Trash"

-- empty: the click landed below the last item, so the menu acts on the folder itself
local where = ya.sync(function(_, empty)
	local tab = cx.active
	local cwd = tostring(tab.current.cwd)
	local h = not empty and tab.current.hovered or nil
	local urls = {}
	for _, u in pairs(empty and {} or tab.selected) do
		urls[#urls + 1] = tostring(u)
	end
	if #urls == 0 and h then
		urls[1] = tostring(h.url)
	end
	return {
		cwd = cwd,
		qa = cwd == QA,
		trash = cwd:find("^trash://") ~= nil,
		trash_root = cwd:find("^trash:///@/*$") ~= nil,
		hovered = h and { dir = h.cha.is_dir, link = h.link_to and tostring(h.link_to), url = tostring(h.url) },
		urls = urls,
		empty = empty,
	}
end)

local function notify(content, level)
	ya.notify { title = "Files", content = content, timeout = 4, level = level or "warn" }
end

-- trash.lua (built in) listens for these; `ya pub` finds this yazi through $YAZI_ID
local function trash_pub(kind, urls)
	local args = { "pub", kind, "--list" }
	for _, u in ipairs(urls or {}) do
		args[#args + 1] = u
	end
	local out = Command("ya"):arg(args):stderr(Command.PIPED):output()
	if not out or not out.status.success then
		notify("Trash: " .. tostring(out and out.stderr or "ya pub failed"), "error")
	end
end

function M.open(w)
	local h = w.hovered
	if not h then
		return
	elseif w.qa and h.link then
		-- Follow the shortcut to the real folder, so going up leaves it like any other folder
		if h.link == TRASH then
			-- Nothing deleted yet means no Trash folder, which trash:// reports as an error; show it empty
			fs.create("dir_all", Url(HOME_TRASH .. "/files"))
			fs.create("dir_all", Url(HOME_TRASH .. "/info"))
			return ya.emit("plugin", { "trash" })
		end
		return ya.emit("cd", { Url(h.link) })
	elseif h.dir then
		return ya.emit("enter", {})
	end
	ya.emit("open", {})
end

function M.delete(w)
	if w.qa then
		return notify("Quick Access only holds shortcuts. Right-click → Unpin to remove a pin.")
	end
	-- Inside Trash, Delete is the only way to delete for real; both ask first
	ya.emit("remove", { permanently = w.trash })
end

-- trash:// has no parent, so going up from it would do nothing; its place is under Quick Access
function M.up(w)
	if w.trash_root then
		return ya.emit("cd", { Url(QA) })
	end
	ya.emit("leave", {})
end

-- Open with…, like Nautilus: the apps installed for the hovered file's type (from their .desktop files,
-- through gio), plus making one of them the default. Opens the selection, or the hovered file
local function app_name(id)
	local dirs = (os.getenv("XDG_DATA_HOME") or HOME .. "/.local/share") .. ":" .. (os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share")
	for dir in dirs:gmatch("[^:]+") do
		local f = io.open(dir .. "/applications/" .. id)
		if f then
			local body = f:read("a")
			f:close()
			return body:match("\nName=([^\n]+)") or id, dir .. "/applications/" .. id
		end
	end
end

function M.openwith(w)
	if not w.hovered then
		return
	end
	local info = Command("gio"):arg({ "info", "-a", "standard::content-type", "--", w.hovered.url }):stdout(Command.PIPED):output()
	local mime = info and info.stdout:match("standard::content%-type: (%S+)")
	local out = mime and Command("gio"):arg({ "mime", mime }):stdout(Command.PIPED):output()
	if not out then
		return notify("Can't tell what kind of file this is")
	end
	local default = out.stdout:match(": (%S+%.desktop)\n")
	local apps, seen = {}, {}
	for id in (out.stdout:match("Registered applications:\n(.-)\n%S") or out.stdout:match("Registered applications:\n(.*)") or ""):gmatch("%s+(%S+%.desktop)") do
		local name, path = app_name(id)
		if name and not seen[id] then
			seen[id] = true
			apps[#apps + 1] = { id = id, name = name .. (id == default and " (default)" or ""), path = path }
		end
	end
	if #apps == 0 then
		return notify("No installed app opens " .. mime)
	end

	local keys = "123456789abcdefghijklmnopqrtuvwxyz"
	local function pick(extra)
		local cands = {}
		for i, app in ipairs(apps) do
			cands[i] = { on = keys:sub(i, i), desc = app.name }
		end
		if extra then
			cands[#cands + 1] = { on = "s", desc = extra }
		end
		return ya.which { cands = cands }
	end
	local i = pick("Set as default…")
	if i == #apps + 1 then
		local j = pick()
		if j then
			-- From ~/.config: gio resolves the stow link to mimeapps.list relative to its working directory
			local cfg = os.getenv("XDG_CONFIG_HOME") or HOME .. "/.config"
			local set = Command("gio"):arg({ "mime", mime, apps[j].id }):cwd(cfg):stderr(Command.PIPED):output()
			if set and set.status.success then
				notify(apps[j].name:gsub(" %(default%)", "") .. " now opens " .. mime, "info")
			else
				notify("Couldn't set the default: " .. tostring(set and set.stderr), "error")
			end
		end
	elseif i then
		local args = { "launch", apps[i].path }
		for _, u in ipairs(w.urls) do
			args[#args + 1] = u
		end
		-- Waited for: gio returns once the app has started, and yazi kills children it drops
		Command("gio"):arg(args):stdout(Command.NULL):stderr(Command.NULL):status()
	end
end

-- Archives: yazi's built-in extract plugin (7-Zip) does the work. It extracts into a hidden temporary
-- folder and renames it only on success, never overwrites (taken names get a suffix), doesn't nest a
-- lone top-level item, asks for passwords and shows progress in the task list.
-- Opening an archive already extracts it next to itself (yazi's default open rule)
local ARCHIVE = { ".zip", ".7z", ".rar", ".tar", ".tgz", ".tbz2", ".txz", ".tar.gz", ".tar.bz2", ".tar.xz",
	".tar.zst", ".iso", ".cab", ".cpio", ".cbz", ".cbr" }

function M.archive(path)
	local lower = path:lower()
	for _, ext in ipairs(ARCHIVE) do
		if lower:sub(-#ext) == ext then
			return true
		end
	end
end

function M.extract_to(w)
	local dest, event = ya.input { title = "Extract to folder:", value = w.cwd, pos = { "top-center", y = 3, w = 60 } }
	if event ~= 1 or dest == "" then
		return
	end
	dest = dest:gsub("^~", HOME):gsub("/+$", "")
	local cha = fs.cha(Url(dest))
	if not (cha and cha.is_dir) then
		return notify(dest .. " isn't a folder")
	elseif not Command("test"):arg({ "-w", dest }):status().success then
		return notify("No permission to write to " .. dest) -- the extract plugin would fail without a word
	end
	for _, u in ipairs(w.urls) do
		ya.emit("plugin", { "extract", ya.quote(u) .. " " .. ya.quote(dest) })
	end
end

function M.home()
	ya.emit("cd", { Url(QA) }) -- the cd hook rebuilds it
end

-- Copy/Cut also put the files on the system clipboard, so the clipboard always holds the newest copy:
-- a screenshot taken afterwards replaces them there, and Paste then saves the image instead
local function yank(w, cut)
	ya.emit("yank", { cut = cut })
	local uris = {}
	for _, u in ipairs(w.urls) do
		uris[#uris + 1] = "file://" .. u:gsub("[^%w/%-._~]", function(c) return string.format("%%%02X", c:byte()) end)
	end
	if #uris > 0 then
		Command("wl-copy"):arg({ "--type", "text/uri-list", table.concat(uris, "\r\n") }):stdout(Command.NULL):stderr(Command.NULL):status()
	end
end

function M.copy(w) yank(w, false) end
function M.cut(w) yank(w, true) end

function M.paste(w)
	local types = not w.trash and Command("wl-paste"):arg({ "--list-types" }):stdout(Command.PIPED):stderr(Command.NULL):output()
	if not (types and types.status.success and types.stdout:find("image/png", 1, true)) then
		return ya.emit("paste", {})
	end
	local base = w.cwd .. "/Screenshot " .. os.date("%Y-%m-%d %H-%M-%S")
	local path, n = base .. ".png", 1
	while fs.cha(Url(path)) do
		n = n + 1
		path = base .. " (" .. n .. ").png"
	end
	local out = Command("sh"):arg({ "-c", 'wl-paste --type image/png > "$1"', "sh", path }):stderr(Command.PIPED):output()
	if not (out and out.status.success) then
		return notify("Couldn't save the image: " .. tostring(out and out.stderr or "wl-paste failed"), "error")
	end
	ya.emit("unyank", {})
	ya.emit("reveal", { Url(path) })
end

-- The selected or hovered items' paths, or on empty space the folder's; Quick Access shortcuts give the real folder
function M.copypath(w)
	local paths = w.empty and { w.cwd } or w.urls
	if #paths == 0 then
		return
	elseif w.qa and not w.empty then
		local out = Command("realpath"):arg({ "--", table.unpack(paths) }):stdout(Command.PIPED):output()
		paths = { out and out.stdout:gsub("\n$", "") or table.concat(paths, "\n") }
	end
	Command("wl-copy"):arg({ "--", table.concat(paths, "\n") }):stdout(Command.NULL):stderr(Command.NULL):status()
end

-- $TERMINAL (kitty if unset) in this folder; Quick Access and Trash aren't real folders, so Home.
-- setsid, so closing yazi doesn't take the terminal with it
function M.terminal(w)
	local dir = (w.qa or w.cwd:sub(1, 1) ~= "/") and HOME or w.cwd
	Command("setsid"):arg({ "-f", os.getenv("TERMINAL") or "kitty" }):cwd(dir)
		:stdout(Command.NULL):stderr(Command.NULL):status()
end

-- The right-click menu as a GUI draws it: a box at the pointer (flipped at the edges), the row under
-- the pointer highlighted, a click runs it, a click elsewhere or Esc closes it. A silent ya.which
-- underneath takes the keys (letters, arrows, Enter), and a click ends that wait with which:dismiss.
local Menu = { _id = "explorer-menu" }
local hover = { url = nil, file = nil, lead = nil, moved = 0, running = false }

function Menu:new(area)
	self._screen = area
	return self
end

function Menu:reflow() return self.rows and { self } or {} end

function Menu:redraw()
	-- Pointer motion (mode 1003) for hover, which yazi never asks for: it sets 1002 at start and again
	-- when it comes back from a program run in the terminal, then redraws, so this re-asserts it.
	-- Here because Modal children are redrawn every frame, menu or not.
	-- Never reset it with 1003l: 1000/1002/1003 are one setting in the terminal, so that would turn
	-- the mouse off entirely, not back to 1002
	io.stdout:write("\27[?1003h")
	io.stdout:flush()
	local rows, s = self.rows, self._screen
	if not rows then
		return {}
	end
	local w, h = 0, #rows + 2
	for _, r in ipairs(rows) do
		w = math.max(w, ui.width(r.desc or "") + #(r.on or "") + 6)
	end
	-- Corner at the pointer, flipped to the other side when it would run off the window
	local x = self.x or (s.w - w) // 2
	local y = self.y or (s.h - h) // 2
	if x + w > s.w then
		x = math.max(0, x - w + 1)
	end
	if y + h > s.h then
		y = math.max(0, y - h + 1)
	end
	self._area = ui.Rect { x = x, y = y, w = math.min(w, s.w), h = math.min(h, s.h) }

	local lines, seps = {}, {}
	for i, r in ipairs(rows) do
		if r.sep then
			-- Drawn over the border so it joins it: ├────┤
			lines[i] = ui.Line("")
			seps[#seps + 1] = ui.Line("├" .. string.rep("─", w - 2) .. "┤")
				:area(ui.Rect { x = x, y = y + i, w = w, h = 1 })
				:style(th.which.border)
		else
			local line = ui.Line {
				ui.Span(" " .. r.desc),
				ui.Span(string.rep(" ", w - 4 - ui.width(r.desc) - #r.on)),
				ui.Span(r.on .. " "):style(th.which.cand),
			}
			lines[i] = i == self.hover and line:style(th.help.hovered) or line
		end
	end
	return ya.list_merge({
		ui.Clear(self._area),
		ui.Border(ui.Edge.ALL):area(self._area):type(ui.Border.ROUNDED):style(th.which.border),
		ui.List(lines):area(self._area:pad(ui.Pad(1, 1, 1, 1))),
	}, seps)
end

-- The row under the pointer, or nil on the border, a separator or outside
function Menu:row_at(event)
	local a = self._area
	if not a or event.x <= a.x or event.x >= a.x + a.w - 1 then
		return nil
	end
	local i = event.y - a.y
	return self.rows[i] and not self.rows[i].sep and i or nil
end

-- picked: the item's number, or nil to just close
function Menu:close(picked)
	self.picked, self.rows, self.hover = picked, nil, nil
	ui.render()
end

-- Clicks and motion go to the menu while it's open; yazi's own Root.click skips everything but the
-- main layer, and ya.which's layer is active underneath
function Menu:click(event, up)
	if up then
		return -- includes the release of the right-click that opened the menu
	end
	local i = event.is_left and self:row_at(event)
	self:close(i and self.rows[i].n)
	ya.emit("which:dismiss", {})
end

function Menu:move(event)
	local i = self:row_at(event)
	if i ~= self.hover then
		self.hover = i
		ui.render()
	end
end

local menu_open = ya.sync(function(_, rows, x, y)
	Menu.rows, Menu.x, Menu.y, Menu.hover, Menu.picked = rows, x, y, nil, nil
	ui.render()
end)

-- One answer from ya.which: an item number (its letter), "up", "down", "enter", or nil (Esc,
-- another key, or a click, which already closed the menu). Returns done and the item to run
local menu_key = ya.sync(function(_, key)
	local rows = Menu.rows
	if not rows then
		return true, Menu.picked
	elseif key == "up" or key == "down" then
		-- No row yet: ↓ starts at the first item, ↑ at the last
		local step, i = key == "up" and -1 or 1, Menu.hover or (key == "up" and #rows + 1 or 0)
		repeat
			i = (i + step - 1) % #rows + 1
		until not rows[i].sep
		Menu.hover = i
		ui.render()
		return false
	elseif key == "enter" then
		if not Menu.hover then
			return false
		end
		key = rows[Menu.hover].n
	end
	Menu:close(key)
	return true, key
end)

-- Items marked file act on the hovered or selected items and are left out on empty space;
-- {} is a separator
function M.menu(w, x, y)
	local items
	if w.qa then
		items = {
			{ on = "o", desc = "Open", file = true, run = function() M.open(w) end },
			{ on = "y", desc = "Copy path", file = true, run = function() M.copypath(w) end },
			{},
			{ on = "u", desc = "Unpin a folder…", run = function() ya.emit("plugin", { "yamb", "delete_by_key" }) end },
		}
	elseif w.trash then
		items = {
			{ on = "r", desc = "Restore", file = true, run = function()
				if #w.urls > 0 then
					trash_pub("trash-restore", w.urls)
				end
			end },
			{ on = "d", desc = "Delete permanently", file = true, run = function() M.delete(w) end },
			{},
			{ on = "s", desc = "Select / Unselect", file = true, run = function() ya.emit("toggle", {}) end },
			{ on = "a", desc = "Select all", run = function() ya.emit("toggle_all", { state = "on" }) end },
			{},
			-- Empties everything; the list is only there because the message can't be empty
			{ on = "e", desc = "Empty Trash", run = function()
				if #w.urls > 0 then
					trash_pub("trash-empty", w.urls)
				end
			end },
		}
	else
		local archive = w.hovered and not w.hovered.dir and M.archive(w.hovered.url)
		local dir = w.hovered and w.hovered.dir
		items = {
			{ on = "o", desc = "Open", file = true, run = function() M.open(w) end },
			{ on = "w", desc = "Open with…", file = true, run = function() M.openwith(w) end },
			archive and { on = "e", desc = "Extract here", run = function() ya.emit("open", {}) end } or false,
			archive and { on = "t", desc = "Extract to…", run = function() M.extract_to(w) end } or false,
			{},
			{ on = "c", desc = "Copy", file = true, run = function() M.copy(w) end },
			{ on = "x", desc = "Cut", file = true, run = function() M.cut(w) end },
			{ on = "v", desc = "Paste", run = function() M.paste(w) end },
			{},
			{ on = "r", desc = "Rename", file = true, run = function() ya.emit("rename", { cursor = "before_ext" }) end },
			{ on = "d", desc = "Move to Trash", file = true, run = function() M.delete(w) end },
			{},
			{ on = "y", desc = w.empty and "Copy folder path" or "Copy path", run = function() M.copypath(w) end },
			{ on = "T", desc = "Open terminal here", run = function() M.terminal(w) end },
			{ on = "n", desc = "New folder", run = function() ya.emit("create", { dir = true }) end },
			dir and { on = "p", desc = "Pin to Quick Access", run = function() ya.emit("plugin", { "yamb", "save" }) end } or false,
			{},
			{ on = "s", desc = "Select / Unselect", file = true, run = function() ya.emit("toggle", {}) end },
			{ on = "a", desc = "Select all", run = function() ya.emit("toggle_all", { state = "on" }) end },
			{ on = "f", desc = "Search…", run = function() ya.emit("search", { via = "fd" }) end },
			{ on = "l", desc = "Filter this folder…", run = function() ya.emit("filter", { smart = true }) end },
			{},
			{ on = "i", desc = "Properties", file = true, run = function() ya.emit("spot", {}) end },
		}
	end

	-- yazi's help lists every key (ours carry a description), searchable by typing
	items[#items + 1] = {}
	items[#items + 1] = { on = "?", desc = "Keyboard shortcuts…", run = function() ya.emit("help", {}) end }

	-- No separator first, last or twice in a row once items are left out
	local shown, rows, cands = {}, {}, {}
	for _, item in ipairs(items) do
		if item and not item.on then
			if #rows > 0 and not rows[#rows].sep then
				rows[#rows + 1] = { sep = true }
			end
		elseif item and not (w.empty and item.file) then
			shown[#shown + 1] = item
			cands[#cands + 1] = { on = item.on, desc = item.desc }
			rows[#rows + 1] = { on = item.on, desc = item.desc, n = #shown }
		end
	end
	if rows[#rows].sep then
		rows[#rows] = nil
	end
	local n = #cands
	cands[n + 1], cands[n + 2], cands[n + 3] = { on = "<Up>" }, { on = "<Down>" }, { on = "<Enter>" }

	menu_open(rows, x, y)
	local done, picked
	repeat
		local i = ya.which { cands = cands, silent = true }
		done, picked = menu_key(i and (i <= n and i or ({ "up", "down", "enter" })[i - n]))
	until done
	if picked then
		shown[picked].run()
	end
end

-- Sizes in SI units, like the drive lines in Quick Access
local function human(b)
	local units, i = { "B", "kB", "MB", "GB", "TB", "PB" }, 1
	while b >= 1000 and i < #units do
		b, i = b / 1000, i + 1
	end
	return string.format((b < 10 and i > 1) and "%.1f %s" or "%.0f %s", b, units[i])
end

-- Status bar like Finder and Nautilus: "17 items, 3 selected (4.2 MB)" on the left, the folder's
-- drive's free space on the right. Replaces yazi's mode, size, name, permissions and position
local free = {} -- folder -> "120 GB free", filled on each visit

local function counts(self)
	local folder = self._current
	local _, err = folder.stage()
	if err then
		return ui.Line(" " .. tostring(err):gsub(" %(os error %d+%)", "")) -- e.g. "Permission denied"
	end
	local n = #folder.files
	local text = string.format(" %d %s", n, n == 1 and "item" or "items")

	local picked = 0
	for _ in pairs(self._tab.selected) do
		picked = picked + 1
	end
	if picked > 0 then
		-- A size only when every selected entry is a file in this folder: folder sizes aren't known
		local size, here = 0, 0
		for _, f in ipairs(folder.files) do
			if f:is_selected() then
				here = here + 1
				size = f.cha.is_dir and math.huge or size + f.cha.len
			end
		end
		text = text .. string.format(", %d selected", picked)
		if here == picked and size < math.huge then
			text = text .. " (" .. human(size) .. ")"
		end
	end
	return ui.Line(text)
end

local function space(self)
	return ui.Line((free[tostring(self._current.cwd)] or "") .. " ")
end

-- Location box (click the header, Ctrl+L): the real path, selectable to copy; a pasted folder opens,
-- a pasted file is highlighted in its folder rather than opened
function M.go(w)
	local value = w.cwd:find("^%a+://") and HOME or w.cwd
	local path, event = ya.input { title = "Location:", value = value, pos = { "top-center", y = 2, w = 80 } }
	if event ~= 1 then
		return
	end
	path = path:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^file://", "")
	path = path:gsub("^~", HOME):gsub("%$HOME", HOME):gsub("%${HOME}", HOME)
	if path == "" then
		return
	elseif path:sub(1, 1) ~= "/" then
		path = w.cwd .. "/" .. path
	end
	local cha = fs.cha(Url(path))
	if not cha then
		return notify("No such file or folder: " .. path)
	end
	ya.emit(cha.is_dir and "cd" or "reveal", { Url(path) })
end

-- setup() runs in the UI; actions run in a separate plugin runtime without Status or Header
function M:setup()
	-- SUPER+V's Clear clipboard (`ya pub-to 0 clipboard-clear --json null`) also forgets files copied here
	ps.sub_remote("clipboard-clear", function() ya.emit("unyank", {}) end)

	-- The address bar: the real path in a rounded accent box across the top; Quick Access and Trash
	-- keep their names, their paths mean nothing. Clicking it opens the Location box
	function Header:cwd()
		local max = self._area.w - self._right_width - 4
		if max <= 0 then
			return ""
		end
		local cwd = tostring(self._current.cwd)
		local s = cwd == QA and "Quick Access" or cwd:find("^trash://") and "Trash" or ya.readable_path(cwd)
		return ui.Span(ui.truncate(s .. self:flags(), { max = max, rtl = true }))
	end
	function Header:redraw()
		local inner = ui.Rect { x = self._area.x + 2, y = self._area.y + 1, w = self._area.w - 4, h = 1 }
		local box = ui.Rect { x = self._area.x, y = self._area.y, w = self._area.w, h = 3 }
		local right = self:children_redraw(self.RIGHT)
		self._right_width = right:width()
		return {
			ui.Border(ui.Edge.ALL):area(box):type(ui.Border.ROUNDED):style(th.mgr.cwd),
			ui.Line(self:children_redraw(self.LEFT)):area(inner),
			ui.Line(right):area(inner):align(ui.Align.RIGHT),
		}
	end
	function Root:layout()
		self._chunks = ui.Layout()
			:direction(ui.Layout.VERTICAL)
			:constraints({
				ui.Constraint.Length(3),
				ui.Constraint.Length(Tabs.height()),
				ui.Constraint.Fill(1),
				ui.Constraint.Length(1),
			})
			:split(self._area)
	end
	function Header:click(event, up)
		if not up and event.is_left and event.y < self._area.y + 3 then
			ya.emit("plugin", { "explorer", "go" })
		end
	end

	for id = 1, 6 do -- yazi's own children: mode, length, name | perm, percent, position
		Status:children_remove(id, id <= 3 and Status.LEFT or Status.RIGHT)
	end
	Status:children_add(counts, 1000, Status.LEFT)
	Status:children_add(space, 1000, Status.RIGHT)

	Modal:children_add(Menu, 10)
	local root_click = Root.click
	function Root:click(event, up)
		if Menu.rows then
			return Menu:click(event, up)
		end
		return root_click(self, event, up)
	end
	function Root:move(event)
		if Menu.rows then
			return Menu:move(event)
		end
		-- The file under the pointer in the middle pane. Through Root's already-built children, not
		-- ya.child_at(self:reflow()) like yazi's clicks: motion comes dozens of times a second
		local file
		for _, tab in ipairs(self._children) do
			for _, c in ipairs(tab._id == "tab" and tab._children or {}) do
				local a = c._area
				if c._id == "current" and event.x >= a.x and event.x < a.x + a.w and event.y >= a.y then
					file = c._folder.window[event.y - a.y + 1]
				end
			end
		end
		local url = file and tostring(file.url)
		-- Only a change of row counts, so a pointer left still (or one the keyboard moved away from)
		-- never pulls the cursor back
		if not url or url == hover.url then
			return
		end
		hover.url, hover.file, hover.lead, hover.moved = url, file.url, url, ya.time()
		if hover.running then
			return
		end
		-- The pointer moves the cursor, but in two steps, since a cursor move also loads the preview:
		-- the highlight follows at once (at most 20 redraws a second), and the cursor itself, with
		-- its preview, follows once the pointer rests on a file for 80 ms
		hover.running = true
		ui.render()
		ya.async(function()
			local drawn = hover.lead
			repeat
				ya.sleep(0.05)
				if hover.lead ~= drawn then
					drawn = hover.lead
					ui.render()
				end
			until not hover.lead or ya.time() - hover.moved >= 0.08
			if hover.lead then
				ya.emit("reveal", { hover.file })
			end
			hover.running = false
		end)
	end

	-- While the cursor hasn't caught up, the row under the pointer looks like the cursor and the
	-- cursor's own row looks plain, so only one row is ever highlighted
	local entity_style = Entity.style
	function Entity:style()
		local f = self._file
		if hover.lead and f.in_current then
			if tostring(f.url) == hover.lead then
				return (f:style() or ui.Style()):patch(th.indicator.current)
			elseif f.is_hovered then
				return f:style() or ui.Style()
			end
		end
		return entity_style(self)
	end

	-- The cursor moved: it caught up with the pointer, or the keyboard (or a click) moved it, which
	-- wins over a pointer still waiting to catch up
	ps.sub("hover", function()
		hover.lead = nil
	end)

	-- yazi also sends cd at startup, so this builds Quick Access on launch and again on each visit,
	-- picking up new mounts, pins and frequent folders
	ps.sub("cd", function()
		local cwd = tostring(cx.active.current.cwd)
		if cwd == QA then
			return ya.async(function() Command(BUILD):status() end)
		elseif cwd:sub(1, 1) ~= "/" then
			return -- trash://, search:// and other virtual folders have no drive
		end
		-- Async so a dead network share can't freeze yazi; cached per folder, so a late answer
		-- only ever fills in its own folder
		ya.async(function()
			local out = Command("timeout"):arg({ "2", "df", "-Pk", "--", cwd }):stdout(Command.PIPED):output()
			local avail = out and out.status.success and out.stdout:match("\n%S+%s+%d+%s+%d+%s+(%d+)")
			free[cwd] = avail and human(tonumber(avail) * 1024) .. " free" or nil
			ui.render()
		end)
	end)
end

-- Preview of the Quick Access Trash entry: what's in Trash, not the empty placeholder it points at.
-- Like trash://, that's the home Trash plus each local drive's own (.Trash-UID or .Trash/UID)
local REMOTE = { autofs = 1, nfs = 1, nfs4 = 1, cifs = 1, smb3 = 1, ["fuse.sshfs"] = 1, ["fuse.rclone"] = 1, davfs = 1 }
function M:peek(job)
	local status = io.open("/proc/self/status")
	local uid = status and status:read("a"):match("\nUid:%s+(%d+)")
	local dirs, seen = { HOME_TRASH .. "/files" }, {}
	for line in io.lines("/proc/self/mounts") do
		local target, fstype = line:match("^%S+ (%S+) (%S+)")
		target = target:gsub("\\(%d%d%d)", function(o) return string.char(tonumber(o, 8)) end)
		if uid and not REMOTE[fstype] and not seen[target] then
			seen[target] = true
			local root = target == "/" and "" or target
			dirs[#dirs + 1] = root .. "/.Trash-" .. uid .. "/files"
			dirs[#dirs + 1] = root .. "/.Trash/" .. uid .. "/files"
		end
	end
	local lines = {}
	for _, dir in ipairs(dirs) do
		for _, f in ipairs(fs.read_dir(Url(dir), { limit = job.area.h }) or {}) do
			lines[#lines + 1] = ui.Line(f.name)
		end
	end
	if #lines == 0 then
		lines[1] = ui.Line("Trash is empty")
	end
	ya.preview_widget(job, ui.Text(lines):area(job.area))
end

function M:seek() end

function M:entry(job)
	local action, w = job.args[1], where(job.args[2] == "empty")
	if M[action] and action ~= "setup" and action ~= "entry" and action ~= "peek" and action ~= "seek" then
		M[action](w, tonumber(job.args[3]), tonumber(job.args[4]))
	end
end

return M
