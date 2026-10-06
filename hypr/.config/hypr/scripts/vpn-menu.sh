#!/usr/bin/env bash
# VPN menu (quick settings popup, `bar-popup toggles`). Every NetworkManager WireGuard connection is a
# choice; at most one is up. Only runs nmcli; the profiles are owned by the user
# (connection.permissions), so nothing asks for a password. Off always works offline.
#   popup click:  vpn-menu.sh          open the menu
#   popup status: vpn-menu.sh status   print status JSON
#   hyprland.lua: vpn-menu.sh apply    bring up the last choice, if any
#
# The choice is saved to a state file and replayed at login instead of NetworkManager's
# autoconnect, so a reboot never depends on NetworkManager state.

state="${XDG_STATE_HOME:-$HOME/.local/state}/vpn"

notify() { notify-send -a "VPN" "$@"; }
pick() { fuzzel --dmenu --index --hide-prompt "$@"; }
save() { mkdir -p "${state%/*}"; echo "$1" >"$state"; }

vpns() { nmcli -t -f NAME,TYPE connection show | awk -F: '$2 == "wireguard" { print $1 }' | sort; }
active() { nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2 == "wireguard" { print $1; exit }'; }

label() {
    case "$1" in
        warp)      echo "Cloudflare WARP" ;;
        proton-jp) echo "Proton · Japan" ;;
        proton-nl) echo "Proton · Netherlands" ;;
        proton-ch) echo "Proton · Switzerland" ;;
        proton-us) echo "Proton · United States" ;;
        *)         echo "$1" ;;
    esac
}

down_all() { for c in $(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2 == "wireguard" { print $1 }'); do nmcli connection down "$c" >/dev/null; done; }

case "$1" in
    status)
        cur=$(active)
        if [ -n "$cur" ]; then
            printf '{"text":"\\ue0da","class":"on","tooltip":"VPN: %s"}\n' "$(label "$cur")"
        else
            printf '{"text":"\\ue0da","class":"off","tooltip":"VPN off"}\n'
        fi ;;
    apply)
        want=$(cat "$state" 2>/dev/null)
        [ -n "$want" ] && [ "$(active)" != "$want" ] && nmcli connection up "$want" >/dev/null ;;
    *)
        cur=$(active)
        mapfile -t names < <(vpns)
        # Same check mark as the Wi-Fi menu
        chk=$'\ue668'
        labels=("   Off")
        [ -z "$cur" ] && labels[0]="$chk  Off"
        for n in "${names[@]}"; do
            mark="   "; [ "$n" = "$cur" ] && mark="$chk  "
            labels+=("$mark$(label "$n")")
        done
        idx=$(printf '%s\n' "${labels[@]}" | pick)
        [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "${#labels[@]}" ] || exit 0
        if [ "$idx" = 0 ]; then
            down_all; save ""; notify "VPN off"
            exit 0
        fi
        want=${names[idx-1]}
        [ "$want" = "$cur" ] && exit 0
        down_all
        if nmcli connection up "$want" >/dev/null; then
            save "$want"; notify "VPN on" "$(label "$want")"
        else
            save ""; notify "Could not start $(label "$want")" "Back on plain internet"
        fi ;;
esac
