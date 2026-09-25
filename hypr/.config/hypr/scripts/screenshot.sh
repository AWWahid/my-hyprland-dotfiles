#!/bin/sh
# Screenshot to the clipboard only; a thumbnail shows bottom-right, click it to annotate in satty.
# Usage: screenshot.sh region|screen|window
# hyprshot's exit status is always 1 (it ends on `pkill hyprpicker`), so a cancelled shot is
# told apart by the clipboard image being unchanged
clip() { wl-paste --type image/png 2>/dev/null | cksum; }
before=$(clip)
case "$1" in
    screen) hyprshot -s --clipboard-only -m output -m active ;;
    window) hyprshot -s --clipboard-only -m window -m active ;;
    *)      hyprshot -s --clipboard-only -m region ;;
esac

# In region mode hyprshot returns as soon as the selection ends, before its capture reaches the
# clipboard: wait up to 2 s for the new image
n=0
while [ "$(clip)" = "$before" ]; do
    [ $n -ge 20 ] && exit
    sleep 0.1
    n=$((n + 1))
done

# Thumbnail for the notification; in RAM, overwritten by the next shot
preview="${XDG_RUNTIME_DIR:-/tmp}/screenshot-preview.png"
wl-paste --type image/png > "$preview"

action=$(notify-send -a Screenshot -h "string:image-path:$preview" \
    --action=default=Edit "Screenshot copied — click to edit")
[ "$action" = "default" ] &&
    wl-paste --type image/png | satty -f - --early-exit --copy-command wl-copy --actions-on-enter save-to-clipboard
