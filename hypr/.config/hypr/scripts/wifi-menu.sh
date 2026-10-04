#!/usr/bin/env bash
# Wi-Fi menu (click the network module in waybar).
# Only runs nmcli commands; never edits NetworkManager config.

notify() { notify-send -a "Wi-Fi" "$@"; }
pick() { fuzzel --dmenu --index --prompt "Wi-Fi: " "$@"; }

# One menu at a time: clicks while it is open or busy are ignored
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/wifi-menu.lock"
flock -n 9 || exit 0

# The radio switch stays "enabled" with no adapter (e.g. a USB dongle unplugged).
# Some drivers hold the kernel's network lock for seconds while starting, which stalls
# NetworkManager too; give up after 1 s so the menu still opens.
if ! timeout 1 nmcli -t -f TYPE device | grep -qx wifi; then
    # A just-plugged adapter shows up in NetworkManager only once its driver is ready
    if [ -n "$(ls /sys/class/ieee80211 2>/dev/null)" ]; then
        [ "$(printf '  Wi-Fi adapter starting… (select to refresh)\n' | pick --lines 1)" = 0 ] && exec "$0"
    else
        notify "No Wi-Fi adapter"
    fi
    exit 0
fi

if [ "$(nmcli -t radio wifi)" != enabled ]; then
    [ "$(printf '  Turn Wi-Fi on\n' | pick --lines 1)" = 0 ] && nmcli radio wifi on && notify "Wi-Fi turned on"
    exit 0
fi

# The cached list opens instantly; only an explicit Rescan waits for a scan
rescan=no
if [ "$1" = rescan ]; then
    rescan=yes
    notify "Scanning…"
fi

labels=("  Rescan" "  Turn Wi-Fi off")
actions=(rescan off)
ssids=("" "")
secs=("" "")

active=$(nmcli -t -f DEVICE,TYPE,STATE dev | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }')
if [ -n "$active" ]; then
    labels+=("  Disconnect"); actions+=(disconnect); ssids+=(""); secs+=("")
fi
fixed=${#labels[@]}

# Terse output escapes ':' inside SSIDs as '\:'. SSID is the last field, so rejoin the rest.
# Fields are re-emitted with \x1f so empty ones survive `read`.
while IFS=$'\x1f' read -r inuse signal security ssid; do
    lock=" "; [ -n "$security" ] && [ "$security" != "--" ] && lock=""
    mark="  "; [ "$inuse" = "*" ] && mark=" "
    labels+=("$mark$lock  $signal%  $ssid"); actions+=(net); ssids+=("$ssid"); secs+=("$security")
done < <(nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID dev wifi list --rescan "$rescan" |
    awk -F: '{ s = $4; for (i = 5; i <= NF; i++) s = s ":" $i; gsub(/\\:/, ":", s)
               if (s != "" && !seen[s]++) printf "%s\x1f%s\x1f%s\x1f%s\n", $1, $2, $3, s }')

# Nothing cached yet (adapter just plugged in): scan in the background instead of blocking the menu
if [ "${#labels[@]}" -eq "$fixed" ] && [ "$rescan" = no ]; then
    nmcli dev wifi rescan >/dev/null 2>&1 &
    labels+=("  Scanning… (select to refresh)"); actions+=(refresh); ssids+=(""); secs+=("")
fi

idx=$(printf '%s\n' "${labels[@]}" | pick)
[[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "${#labels[@]}" ] || exit 0

case "${actions[idx]}" in
    rescan)     exec "$0" rescan ;;
    refresh)    exec "$0" ;;
    off)        nmcli radio wifi off && notify "Wi-Fi turned off" ;;
    disconnect) nmcli dev disconnect "$active" >/dev/null && notify "Disconnected" ;;
    net)
        ssid=${ssids[idx]}
        sec=${secs[idx]}
        # Connecting can take many seconds; later notifications replace this one
        connecting() { nid=$(notify -p "Connecting to $ssid…"); notify() { notify-send -a "Wi-Fi" -r "$nid" "$@"; }; }
        if nmcli -t -f NAME con show | grep -Fxq -- "$ssid"; then
            # Saved network
            connecting
            if nmcli con up id "$ssid" >/dev/null; then notify "Connected to $ssid"; else notify "Could not connect to $ssid"; fi
        elif [ -n "$sec" ] && [ "$sec" != "--" ]; then
            pass=$(fuzzel --dmenu --prompt-only "Password for $ssid: " --password)
            [ -n "$pass" ] || exit 0
            connecting
            if nmcli dev wifi connect "$ssid" password "$pass" >/dev/null; then
                notify "Connected to $ssid"
            else
                # Drop the profile this attempt just created so a retry asks for the password again
                nmcli con delete id "$ssid" >/dev/null 2>&1
                notify "Could not connect to $ssid" "Wrong password?"
            fi
        else
            connecting
            if nmcli dev wifi connect "$ssid" >/dev/null; then notify "Connected to $ssid"; else notify "Could not connect to $ssid"; fi
        fi
        ;;
esac
