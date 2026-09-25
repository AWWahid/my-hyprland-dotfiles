#!/usr/bin/env bash
# Power button menu: opens above waybar's power button (also SUPER+Escape). Restart, Shut Down and
# Log Out ask for confirmation first; Cancel is listed first, so a stray double Enter
# cancels instead of confirming. Callers run `pkill -x fuzzel || power-button-menu.sh`, so a
# second click closes it.

# No search line: every menu is short enough to click, and typing only filtered it
pick() { fuzzel --dmenu --index --hide-prompt --minimal-lines "$@"; }

name=$(getent passwd "$USER" | cut -d: -f5 | cut -d, -f1)
[ -n "$name" ] || name=$USER

labels=("  Sleep" "  Restart…" "  Shut Down…" "  Lock Screen" "  Log Out $name…")
commands=(
    "systemctl suspend"
    "systemctl reboot"
    "systemctl poweroff"
    "loginctl lock-session"
    "command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'"
)
# Question and button for the entries that need confirmation, by index
questions=([1]="Are you sure you want to restart your computer now?"
    [2]="Are you sure you want to shut down your computer now?"
    [4]="Are you sure you want to quit all applications and log out now?")
buttons=([1]="Restart" [2]="Shut Down" [4]="Log Out")

# Bottom-left, just above the bar, like the button it opens from
index=$(printf '%s\n' "${labels[@]}" | pick --anchor bottom-left --x-margin 6 --y-margin 6 \
    --width 24 --line-height 30 --lines ${#labels[@]}) || exit 0
[ -n "$index" ] || exit 0

if [ -n "${questions[$index]}" ]; then
    answer=$(printf '  Cancel\n  %s\n' "${buttons[$index]}" | pick --anchor center --y-margin 0 --width 40 --line-height 30 --lines 2 \
        --mesg "${questions[$index]}") || exit 0
    [ "$answer" = 1 ] || exit 0
fi
exec sh -c "${commands[$index]}"
