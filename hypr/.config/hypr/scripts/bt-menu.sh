#!/usr/bin/env bash
# Bluetooth menu (click the bluetooth module in waybar). Uses bluetoothctl only.

notify() { notify-send -a "Bluetooth" "$@"; }
pick() { fuzzel --dmenu --index --prompt "Bluetooth: " "$@"; }

if ! bluetoothctl show >/dev/null 2>&1 || bluetoothctl show | grep -q 'No default controller'; then
    notify "No Bluetooth adapter available" "Is bluetooth.service running?"
    exit 1
fi

if ! bluetoothctl show | grep -q 'Powered: yes'; then
    if [ "$(printf '  Turn Bluetooth on\n' | pick --lines 1)" = 0 ]; then
        bluetoothctl power on >/dev/null && exec "$0"
    fi
    exit 0
fi

if [ "$1" = scan ]; then
    notify "Scanning for 15 seconds…" "Put your device in pairing mode"
    bluetoothctl pairable on >/dev/null
    bluetoothctl --timeout 15 scan on >/dev/null
fi

# Battery level straight from the device's GATT Battery Level characteristic (0x2a19).
# Some mice expose it but BlueZ never fills in its own Battery Percentage for them.
gatt_battery() {
    local path char
    path=/org/bluez/hci0/dev_${1//:/_}
    for char in $(busctl tree --list org.bluez 2>/dev/null | grep "^$path/service[0-9a-f]*/char[0-9a-f]*$"); do
        busctl get-property org.bluez "$char" org.bluez.GattCharacteristic1 UUID 2>/dev/null | grep -q '"00002a19-' || continue
        timeout 3 busctl call org.bluez "$char" org.bluez.GattCharacteristic1 ReadValue 'a{sv}' 0 2>/dev/null | awk '{print $3}'
        return
    done
}

labels=("  Scan for devices" "  Turn Bluetooth off")
actions=(scan off)
macs=("" "")

while read -r _ mac name; do
    info=$(bluetoothctl info "$mac")
    # Skip nearby devices that never broadcast a name (they'd only show as an address)
    grep -q 'Paired: yes' <<<"$info" || grep -q '^\s*Name:' <<<"$info" || continue
    case $(sed -n 's/^\s*Icon: //p' <<<"$info") in
        input-mouse) name="$name  (mouse)" ;;
        input-keyboard) name="$name  (keyboard)" ;;
        audio-*) name="$name  (audio)" ;;
    esac
    if grep -q 'Connected: yes' <<<"$info"; then
        # "Battery Percentage: 0x55 (85)", present only once the device has reported it
        battery=$(sed -n 's/^\s*Battery Percentage: .*(\([0-9]*\))/\1/p' <<<"$info")
        [ -z "$battery" ] && grep -q 'UUID: Battery Service' <<<"$info" && battery=$(gatt_battery "$mac")
        labels+=("  $name  (connected${battery:+, $battery%})"); actions+=(disconnect)
    elif grep -q 'Paired: yes' <<<"$info"; then
        labels+=("  $name"); actions+=(connect)
    else
        labels+=("  $name  (new)"); actions+=(pair)
    fi
    macs+=("$mac")
done < <(bluetoothctl devices)

idx=$(printf '%s\n' "${labels[@]}" | pick)
[[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "${#labels[@]}" ] || exit 0

mac=${macs[idx]}
name=${labels[idx]#*  }
case "${actions[idx]}" in
    scan)       exec "$0" scan ;;
    off)        bluetoothctl power off >/dev/null && notify "Bluetooth turned off" ;;
    disconnect) bluetoothctl disconnect "$mac" >/dev/null && notify "Disconnected" "$name" ;;
    connect)    if bluetoothctl connect "$mac" >/dev/null; then notify "Connected" "$name"; else notify "Could not connect" "$name"; fi ;;
    pair)
        # Trusted devices reconnect automatically whenever Bluetooth is on
        if bluetoothctl --agent NoInputNoOutput pair "$mac" >/dev/null &&
           bluetoothctl trust "$mac" >/dev/null &&
           bluetoothctl connect "$mac" >/dev/null; then
            notify "Paired and connected" "$name"
        else
            notify "Pairing failed" "$name"
        fi
        ;;
esac
