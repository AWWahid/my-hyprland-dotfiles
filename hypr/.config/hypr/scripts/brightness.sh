#!/usr/bin/env bash
# Screen brightness up/down: brightnessctl on a backlight (laptop panel), else DDC/CI via
# ddcutil (external monitor; needs ddcutil, the i2c-dev module and DDC/CI on in the monitor menu).
#   brightness.sh + | -
step=5
if ls /sys/class/backlight/* >/dev/null 2>&1; then
    exec brightnessctl -e4 -n2 set "$step%$1"
fi
# Held keys repeat faster than a DDC write; drop presses while one is running.
# --skip-ddc-checks: ~0.5 s per press instead of ~8.6 s (default re-probes the monitor every call)
exec flock -n "${XDG_RUNTIME_DIR:-/tmp}/brightness.lock" ddcutil --noverify --skip-ddc-checks setvcp 10 "$1" "$step"
