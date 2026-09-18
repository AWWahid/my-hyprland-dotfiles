#!/bin/sh
# Toggle btop in the activity-monitor window. Usage: activity-monitor.sh [preset]
# btop drops a whole preset naming a GPU it can't read, so the GPU box is added
# to the Performance preset only when one is readable.
pkill -x btop && exit

conf=~/.config/btop/btop.conf
gpu=
for drv in /sys/class/drm/card[0-9]*/device/driver; do
    case $(basename "$(readlink "$drv")") in
        nvidia) gpu=1 ;;
        amdgpu) ldconfig -p | grep -q librocm_smi64 && gpu=1 ;;
        # Intel counters need CAP_PERFMON (set via /etc/permissions.local) or a relaxed perf_event_paranoid
        i915|xe) { getfattr -n security.capability /usr/bin/btop >/dev/null 2>&1 ||
                   [ "$(cat /proc/sys/kernel/perf_event_paranoid)" -le 0 ]; } && gpu=1 ;;
    esac
done

if [ -n "$gpu" ]; then
    tmp=$XDG_RUNTIME_DIR/btop.conf
    sed '/^presets = /s/"$/,gpu0:0:braille"/' "$conf" > "$tmp"
    conf=$tmp
fi

exec kitty --class activity-monitor -c ~/.config/kitty/activity.conf -e btop -c "$conf" -p "${1:-1}"
