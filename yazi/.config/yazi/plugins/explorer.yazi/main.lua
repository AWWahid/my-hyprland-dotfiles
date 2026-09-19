--- @since 26.8.15
-- File-explorer behaviour on top of yazi: the Quick Access start folder (built by
-- quick-access.sh), a Trash-aware Delete, the right-click menu and a Finder-style status bar.
-- Entry: `plugin explorer -- open|delete|menu|home`.

local M = {}

local HOME = os.getenv("HOME")
local QA = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi/quick-access"
local TRASH = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi/trash-shortcut"
local BUILD = HOME .. "/.config/yazi/quick-access.sh"
local HOME_TRASH = (os.getenv("XDG_DATA_HOME") or HOME .. "/.local/share") .. "/Trash"

local where = ya.sync(function()
	local tab = cx.active
	local cwd = tostring(tab.current.cwd)
	local h = tab.current.hovered
	local urls = {}
	for _, u in pairs(tab.selected) do
		urls[#urls + 1] = tostring(u)
	end
	if #urls == 0 and h then
		urls[1] = tostring(h.url)
	end
	return {
		qa = cwd == QA,
		trash = cwd:find("^trash://") ~= nil,
		hovered = h and { dir = h.cha.is_dir, link = h.link_to and tostring(h.link_to) },
		urls = urls,
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

function M.home()
	ya.emit("cd", { Url(QA) }) -- the cd hook rebuilds it
end

function M.menu(w)
	local items
	if w.qa then
		items = {
			{ on = "o", desc = "Open", run = function() M.open(w) end },
			{ on = "u", desc = "Unpin a folder…", run = function() ya.emit("plugin", { "yamb", "delete_by_key" }) end },
		}
	elseif w.trash then
		items = {
			{ on = "r", desc = "Restore", run = function()
				if #w.urls > 0 then
					trash_pub("trash-restore", w.urls)
				end
			end },
			{ on = "d", desc = "Delete permanently", run = function() M.delete(w) end },
			-- Empties everything; the list is only there because the message can't be empty
			{ on = "e", desc = "Empty Trash", run = function()
				if #w.urls > 0 then
					trash_pub("trash-empty", w.urls)
				end
			end },
		}
	else
		items = {
			{ on = "o", desc = "Open", run = function() M.open(w) end },
			{ on = "w", desc = "Open with…", run = function() ya.emit("open", { interactive = true }) end },
			{ on = "r", desc = "Rename", run = function() ya.emit("rename", { cursor = "before_ext" }) end },
			{ on = "c", desc = "Copy", run = function() ya.emit("yank", {}) end },
			{ on = "x", desc = "Cut", run = function() ya.emit("yank", { cut = true }) end },
			{ on = "v", desc = "Paste", run = function() ya.emit("paste", {}) end },
			{ on = "n", desc = "New folder", run = function() ya.emit("create", { dir = true }) end },
			{ on = "d", desc = "Move to Trash", run = function() M.delete(w) end },
			{ on = "i", desc = "Properties", run = function() ya.emit("spot", {}) end },
		}
		if w.hovered and w.hovered.dir then
			table.insert(items, 8, { on = "p", desc = "Pin to Quick Access", run = function() ya.emit("plugin", { "yamb", "save" }) end })
		end
	end

	local cands = {}
	for i, item in ipairs(items) do
		cands[i] = { on = item.on, desc = item.desc }
	end
	local idx = ya.which { cands = cands }
	if idx then
		items[idx].run()
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

function M:entry(job)
	local action, w = job.args[1], where()
	if M[action] and action ~= "setup" and action ~= "entry" then
		M[action](w)
	end
end

return M
