--- @since 26.8.15
-- File-explorer behaviour on top of yazi: the Quick Access start folder (built by
-- quick-access.sh), a Trash-aware Delete, the right-click menu and a Finder-style status bar.
-- Entry: `plugin explorer -- open|openwith|delete|up|menu [empty]|home|copy|cut|paste|copypath|terminal`; also previews the Trash entry.

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

-- Items marked file act on the hovered or selected items and are left out on empty space
function M.menu(w)
	local items
	if w.qa then
		items = {
			{ on = "o", desc = "Open", file = true, run = function() M.open(w) end },
			{ on = "y", desc = "Copy path", file = true, run = function() M.copypath(w) end },
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
			{ on = "s", desc = "Select / Unselect", file = true, run = function() ya.emit("toggle", {}) end },
			{ on = "a", desc = "Select all", run = function() ya.emit("toggle_all", { state = "on" }) end },
			-- Empties everything; the list is only there because the message can't be empty
			{ on = "e", desc = "Empty Trash", run = function()
				if #w.urls > 0 then
					trash_pub("trash-empty", w.urls)
				end
			end },
		}
	else
		items = {
			{ on = "o", desc = "Open", file = true, run = function() M.open(w) end },
			{ on = "w", desc = "Open with…", file = true, run = function() M.openwith(w) end },
			{ on = "r", desc = "Rename", file = true, run = function() ya.emit("rename", { cursor = "before_ext" }) end },
			{ on = "c", desc = "Copy", file = true, run = function() M.copy(w) end },
			{ on = "x", desc = "Cut", file = true, run = function() M.cut(w) end },
			{ on = "v", desc = "Paste", run = function() M.paste(w) end },
			{ on = "y", desc = w.empty and "Copy folder path" or "Copy path", run = function() M.copypath(w) end },
			{ on = "T", desc = "Open terminal here", run = function() M.terminal(w) end },
			{ on = "n", desc = "New folder", run = function() ya.emit("create", { dir = true }) end },
			{ on = "d", desc = "Move to Trash", file = true, run = function() M.delete(w) end },
			{ on = "i", desc = "Properties", file = true, run = function() ya.emit("spot", {}) end },
			{ on = "s", desc = "Select / Unselect", file = true, run = function() ya.emit("toggle", {}) end },
			{ on = "a", desc = "Select all", run = function() ya.emit("toggle_all", { state = "on" }) end },
			{ on = "f", desc = "Search…", run = function() ya.emit("search", { via = "fd" }) end },
			{ on = "l", desc = "Filter this folder…", run = function() ya.emit("filter", { smart = true }) end },
		}
		if w.hovered and not w.hovered.dir and M.archive(w.hovered.url) then
			table.insert(items, 3, { on = "e", desc = "Extract here", run = function() ya.emit("open", {}) end })
			table.insert(items, 4, { on = "t", desc = "Extract to…", run = function() M.extract_to(w) end })
		end
		if w.hovered and w.hovered.dir then
			table.insert(items, #items - 5, { on = "p", desc = "Pin to Quick Access", run = function() ya.emit("plugin", { "yamb", "save" }) end })
		end
	end

	-- yazi's help lists every key (ours carry a description), searchable by typing
	items[#items + 1] = { on = "?", desc = "Keyboard shortcuts…", run = function() ya.emit("help", {}) end }

	local shown, cands = {}, {}
	for _, item in ipairs(items) do
		if not (w.empty and item.file) then
			shown[#shown + 1] = item
			cands[#cands + 1] = { on = item.on, desc = item.desc }
		end
	end
	local idx = ya.which { cands = cands }
	if idx then
		shown[idx].run()
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

-- setup() runs in the UI; actions run in a separate plugin runtime without Status or Header
function M:setup()
	-- SUPER+V's Clear clipboard (`ya pub-to 0 clipboard-clear --json null`) also forgets files copied here
	ps.sub_remote("clipboard-clear", function() ya.emit("unyank", {}) end)

	-- The location bar names places instead of showing their paths
	local header_cwd = Header.cwd
	function Header:cwd()
		local cwd = tostring(self._current.cwd)
		if cwd == QA then
			return ui.Span("Quick Access"):style(th.mgr.cwd)
		elseif cwd:find("^trash://") then
			return ui.Span("Trash"):style(th.mgr.cwd)
		end
		return header_cwd(self)
	end

	for id = 1, 6 do -- yazi's own children: mode, length, name | perm, percent, position
		Status:children_remove(id, id <= 3 and Status.LEFT or Status.RIGHT)
	end
	Status:children_add(counts, 1000, Status.LEFT)
	Status:children_add(space, 1000, Status.RIGHT)

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
		M[action](w)
	end
end

return M
