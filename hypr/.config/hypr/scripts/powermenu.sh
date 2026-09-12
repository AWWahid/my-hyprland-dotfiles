#!/usr/bin/env bash
# Power menu (SUPER+Escape / waybar power button)

choice=$(printf '%s\n' "󰌾  Lock" "󰍃  Logout" "󰤄  Suspend" "󰜉  Reboot" "󰐥  Shutdown" |
    fuzzel --dmenu --prompt "Power: " --lines 5)

case "$choice" in
    *Lock)     loginctl lock-session ;;
    *Logout)   command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()' ;;
    *Suspend)  systemctl suspend ;;
    *Reboot)   systemctl reboot ;;
    *Shutdown) systemctl poweroff ;;
esac
