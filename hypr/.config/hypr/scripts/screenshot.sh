#!/bin/sh
# Windows-style screenshot: capture to clipboard only, click the notification to annotate in satty.
# Usage: screenshot.sh region|screen|window
case "$1" in
    screen) hyprshot -s --clipboard-only -m output -m active ;;
    window) hyprshot -s --clipboard-only -m window -m active ;;
    *)      hyprshot -s --clipboard-only -m region ;;
esac || exit

# Wait for hyprshot's wl-copy to own the clipboard before offering the edit action
sleep 0.2
wl-paste --list-types | grep -q '^image/png' || exit

action=$(notify-send -a Screenshot -i image-x-generic \
    --action=default=Edit "Screenshot copied" "Click to edit")
[ "$action" = "default" ] &&
    wl-paste --type image/png | satty -f - --early-exit --copy-command wl-copy --actions-on-enter save-to-clipboard
