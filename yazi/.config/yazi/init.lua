-- Every folder visited feeds zoxide, which ranks Quick Access's frequent folders
require("zoxide"):setup { update_db = true }

-- Pinned folders; kept out of this repo like the rest of yazi's state
require("yamb"):setup {
	path = (os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/yazi/bookmarks",
}

require("explorer"):setup()

-- Mouse like a GUI file manager: click selects, double-click opens, right-click opens the action menu
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
