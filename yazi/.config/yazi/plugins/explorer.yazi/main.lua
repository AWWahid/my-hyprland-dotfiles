--- @since 26.8.15
-- File-explorer behaviour on top of yazi: the Quick Access start folder (built by
-- quick-access.sh), a Trash-aware Delete, and the right-click menu.
-- Entry: `plugin explorer -- open|delete|menu|home`.

local M = {}

local HOME = os.getenv("HOME")
local QA = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi/quick-access"
local TRASH = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/yazi/trash-shortcut"
local BUILD = HOME .. "/.config/yazi/quick-access.sh"

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
	Command(BUILD):status()
	ya.emit("cd", { Url(QA) })
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

-- Rebuilt on each visit so new mounts, pins and frequent folders show up
function M:setup()
	ps.sub("cd", function()
		if tostring(cx.active.current.cwd) == QA then
			ya.async(function() Command(BUILD):status() end)
		end
	end)
end

function M:entry(job)
	local action, w = job.args[1], where()
	if M[action] and action ~= "setup" and action ~= "entry" then
		M[action](w)
	end
end

return M
