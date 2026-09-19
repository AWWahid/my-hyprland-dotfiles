#!/usr/bin/env bash
# Night Shift (waybar module in the chevron). Warms the screen's white point with
# hyprsunset; no brightness or gamma change. hyprsunset runs only while it's on.
#   click: toggle   scroll: warmer / less warm   no argument: print waybar JSON

state="${XDG_STATE_HOME:-$HOME/.local/state}/nightshift"
min=2700 max=5700 step=300
temp=$(cat "$state" 2>/dev/null || echo 4100)
running() { pgrep -x hyprsunset >/dev/null; }
save() { mkdir -p "${state%/*}"; echo "$temp" >"$state"; }
refresh() { pkill -RTMIN+9 waybar; }

case "$1" in
    toggle)
        if running; then pkill -x hyprsunset; while running; do sleep 0.05; done
        else setsid -f hyprsunset -t "$temp" >/dev/null 2>&1; sleep 0.2
        fi
        refresh ;;
    warmer|cooler)
        [ "$1" = warmer ] && temp=$((temp - step)) || temp=$((temp + step))
        temp=$((temp < min ? min : temp > max ? max : temp))
        save
        running && hyprctl hyprsunset temperature "$temp" >/dev/null
        refresh ;;
    *)
        warmth=$(( (max - temp) * 100 / (max - min) ))
        if running; then
            printf '{"text":"\\uf03d","class":"on","tooltip":"Night Shift on · warmth %s%%"}\n' "$warmth"
        else
            printf '{"text":"\\uf03d","class":"off","tooltip":"Night Shift off · warmth %s%%"}\n' "$warmth"
        fi ;;
esac
