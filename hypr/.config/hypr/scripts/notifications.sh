#!/bin/sh
# macOS-style notification centre (fuzzel) and Do Not Disturb for mako, shown as one waybar slot.
# mako's own history can only restore the newest entry, so on-notify logs each notification here
# (tmpfs, cleared at logout) and entries can be removed one at a time. Nothing runs between events.
# mako:   notifications.sh add|rm|open ID
# waybar: notifications.sh status|centre|dnd
log=$XDG_RUNTIME_DIR/notifications.jsonl
max=50

refresh() { pkill -RTMIN+8 -x waybar; }
dnd_on() { makoctl mode | grep -qx do-not-disturb; }
count() { [ -f "$log" ] && wc -l < "$log" || echo 0; }

case "$1" in
add)
    # A replaced notification (same id) keeps one entry
    [ -f "$log" ] && sed -i "/^{\"id\":$2,/d" "$log"
    makoctl list -j | jq -c --argjson id "$2" \
        '.[] | select(.id == $id) | {id, app: .app_name, entry: .desktop_entry, summary, body, t: (now | floor)}' >> "$log"
    [ "$(count)" -gt $max ] && sed -i 1d "$log"
    refresh
    ;;
rm)
    [ -f "$log" ] && sed -i "/^{\"id\":$2,/d" "$log"
    refresh
    ;;
open)
    if makoctl list -j | jq -e --argjson id "$2" 'any(.[]; .id == $id)' > /dev/null; then
        # Still showing: the app is listening, so run its real action
        makoctl invoke -n "$2"
        makoctl dismiss -n "$2"
    else
        # Gone (its actions died with it): focus the app's window, else launch the app
        app=$(grep "^{\"id\":$2," "$log" | jq -r '.entry // .app | ascii_downcase')
        addr=$(hyprctl clients -j | jq -r --arg a "$app" 'first(.[] | (.class | ascii_downcase) as $c
            | select($c == $a or ($c | endswith("." + $a)) or ($a | endswith("." + $c)))) | .address')
        if [ -n "$addr" ]; then
            hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" > /dev/null
        elif [ -n "$app" ]; then
            desktop=$(find ~/.local/share/applications /usr/share/applications -iname "*$app.desktop" 2>/dev/null | head -n 1)
            [ -n "$desktop" ] && gtk-launch "$(basename "$desktop" .desktop)" 2>/dev/null
        fi
    fi
    "$0" rm "$2"
    ;;
status)
    n=$(count)
    if dnd_on; then
        icon=$(printf '\356\275\204') class=dnd tip="Do Not Disturb"   # U+EF44 bedtime
    elif [ "$n" -gt 0 ]; then
        icon=$(printf '\357\223\276') class=unread tip="$n notification"; [ "$n" -gt 1 ] && tip="${tip}s"   # U+F4FE notifications_unread
    else
        icon=$(printf '\356\237\264') class=empty tip="No notifications"   # U+E7F4 notifications
    fi
    printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$icon" "$class" "$tip"
    ;;
centre)
    moon=$(printf '\356\275\204') clear=$(printf '\356\227\215')   # U+EF44 bedtime, U+E5CD close
    dnd_on && dnd="$moon  Turn off Do Not Disturb" || dnd="$moon  Turn on Do Not Disturb"
    # Rows 0-1 are controls, then the log newest first
    choice=$({
        printf '%s\n' "$dnd" "$clear  Clear all"
        [ -f "$log" ] && tac "$log" | jq -r --argjson now "$(date +%s)" '
            ($now - .t) as $s
            | (if $s < 60 then "now" elif $s < 3600 then "\($s / 60 | floor)m"
               elif $s < 86400 then "\($s / 3600 | floor)h" else "\($s / 86400 | floor)d" end) as $ago
            | "\(.app // .entry)  ·  \(.summary) — \(.body // "" | gsub("\\s+"; " "))  ·  \($ago)"'
    } | fuzzel --dmenu --index --no-sort --minimal-lines --lines 12 --width 40 \
        --anchor top-right --x-margin 16 --y-margin 16 --prompt "Notifications: ") || exit 0

    case "$choice" in
    0) "$0" dnd ;;
    1) : > "$log"; makoctl dismiss --all; refresh ;;
    *)
        line=$(($(count) - choice + 2))
        id=$(sed -n "${line}s/^{\"id\":\([0-9]*\),.*/\1/p" "$log")
        [ -n "$id" ] || exit 0
        open=$(printf '\356\242\236')   # U+E89E open_in_new
        case $(printf '%s\n' "$open  Open" "$clear  Remove" | fuzzel --dmenu --index --lines 2 --width 20 \
            --anchor top-right --x-margin 16 --y-margin 16 --prompt "Notification: ") in
        0) "$0" open "$id" ;;
        1) makoctl dismiss -n "$id" 2>/dev/null; "$0" rm "$id"; exec "$0" centre ;;
        *) exec "$0" centre ;;   # Escape goes back to the list
        esac
        ;;
    esac
    ;;
dnd)
    makoctl mode -t do-not-disturb > /dev/null
    refresh
    ;;
esac
