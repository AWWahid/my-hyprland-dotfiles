-- Every folder visited feeds zoxide, which ranks Quick Access's frequent folders
require("zoxide"):setup { update_db = true }

-- Pinned folders; kept out of this repo like the rest of yazi's state
require("yamb"):setup {
	path = (os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/yazi/bookmarks",
}

-- Copy or Cut in one yazi window, Paste in another
require("session"):setup { sync_yanked = true }

require("explorer"):setup()

-- Mouse like a GUI file manager: click selects, double-click opens, right-click opens the action menu,
-- and dragging from one item to another selects everything between them
local last = { url = nil, at = 0 }
function Entity:click(event, up)
	if up or event.is_middle then
		return
	end
	local url = tostring(self._file.url)
	ya.emit("reveal", { self._file.url })

	if event.is_right then
		last.url = nil
		ya.emit("plugin", { "explorer", "menu" })
	elseif last.url == url and ya.time() - last.at < 0.4 then
		last.url = nil
		ya.emit("plugin", { "explorer", "open" })
	else
		last.url, last.at = url, ya.time()
	end
end

-- yazi's file list ignores button releases; catch them to select the dragged-over range.
-- Starting below the last item counts as starting on it, like dragging from empty space
local press
local current_click = Current.click
function Current:click(event, up)
	local all = self._folder.files
	local file = self._folder.window[event.y - self._area.y + 1]
	if not up then
		local start = file or all[#all]
		press = event.is_left and start and tostring(start.url) or nil
		return current_click(self, event, up)
	end
	local from, to = press, file and tostring(file.url)
	press = nil
	if not (event.is_left and from and to) or from == to then
		return
	end
	ya.emit("escape", { select = true })
	local inside = false
	for _, f in ipairs(all) do
		local u = tostring(f.url)
		local edge = u == from or u == to
		if edge then
			inside = not inside
		end
		if edge or inside then
			ya.emit("reveal", { f.url }) -- toggle only acts on the hovered item
			ya.emit("toggle", { state = "on" })
		end
	end
	ya.emit("reveal", { file.url })
end
