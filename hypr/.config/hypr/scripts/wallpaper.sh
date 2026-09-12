#!/usr/bin/env bash
# Wallpaper picker (SUPER+W / waybar). Drop images into ~/Pictures/Wallpapers to add more.
# hyprpaper.conf points at $link, so the choice survives restarts.

dir="$HOME/Pictures/Wallpapers"
link="$HOME/.local/share/wallpaper/current"

choice=$(find "$dir" -maxdepth 1 -xtype f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%f\n' |
    sort | fuzzel --dmenu --prompt "Wallpaper: ")
[ -n "$choice" ] && [ -e "$dir/$choice" ] || exit 0

mkdir -p "$(dirname "$link")"
ln -sfn "$dir/$choice" "$link"

# Apply live; if hyprpaper isn't reachable, restart it (it reads the symlink on start)
hyprctl hyprpaper wallpaper ",$dir/$choice" >/dev/null 2>&1 || {
    pkill -x hyprpaper
    setsid -f hyprpaper >/dev/null 2>&1
}
