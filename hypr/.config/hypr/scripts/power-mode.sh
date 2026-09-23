#!/usr/bin/env bash
# Power menu (click the battery module in waybar). Owns three CPU power knobs
# outright - TLP no longer sets them (see tlp/01-dotfiles.conf), because it re-applied
# its own values on every resume and every charger event and wiped the choice.
#   waybar:       power-mode.sh          open the menu
#   hyprland.lua: power-mode.sh apply    write the last choice, or the defaults
#
# Writing to /sys needs the video group; tmpfiles/99-cpu-power.conf grants it (see
# CLAUDE.md). Current values are read back from sysfs rather than the state file, so
# the menu can never show something the CPU isn't actually doing.

pstate=/sys/devices/system/cpu/intel_pstate
epps=/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
state="${XDG_STATE_HOME:-$HOME/.local/state}/power-mode"

notify() { notify-send -a "Power" "$@"; }
pick() { fuzzel --dmenu --index --prompt "Power: " "$@"; }

epp_now() { cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference; }
flag_now() { [ "$(cat "$1")" = 1 ] && echo on || echo off; }
cap_now() { cat $pstate/max_perf_pct; }
# A cap as the clock it allows on the fastest core, e.g. 60 -> 2.6 GHz
ghz() { sort -n /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq | tail -1 |
    awk -v pct="$1" '{ printf "%.1f GHz", $1 * pct / 1e8 }'; }

set_epp() { for f in $epps; do echo "$1" >"$f"; done; }
set_cap() { echo "$1" >$pstate/max_perf_pct; }
set_boost() { [ "$1" = on ] && echo 1 >$pstate/hwp_dynamic_boost || echo 0 >$pstate/hwp_dynamic_boost; }

save() {
    mkdir -p "${state%/*}"
    printf 'epp=%s\ncap=%s\nboost=%s\n' \
        "$(epp_now)" "$(cap_now)" "$(flag_now $pstate/hwp_dynamic_boost)" >"$state"
}

# Battery-first defaults, used until the menu is opened for the first time. This CPU
# (i5-1235U) runs intel_pstate in active mode with HWP, so the governor is only a hint
# and EPP is the real lever. Turbo stays on - base clock alone (1.3 GHz) made the
# desktop feel sluggish - and max_perf_pct caps how far it climbs instead. It is a
# percentage of the top turbo clock (4.4 GHz on the P-cores; the E-cores scale to their
# own 3.3), so 60 stops the P-cores at ~2.6 GHz: enough headroom for page loads and app
# starts, while the top bins, which cost the most power per clock (voltage squared),
# stay out of reach. 30 or below is base clock again, i.e. turbo off.
defaults() { printf 'epp=power\ncap=60\nboost=off\n'; }

# Write the knobs. Runs at login and again after resume; silent either way.
if [ "$1" = apply ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            epp) set_epp "$value" ;;
            cap) set_cap "$value" ;;
            boost) set_boost "$value" ;;
        esac
    done < <([ -r "$state" ] && cat "$state" || defaults)
    exit 0
fi

# Mark the value that is in effect, so a submenu shows where you are before you change it
mark() { [ "$1" = "$2" ] && printf '  %s  ✓\n' "$1" || printf '  %s\n' "$1"; }

choose() { # choose <current> <value>...
    local current=$1
    shift
    for value in "$@"; do mark "$value" "$current"; done | pick --lines $#
}

labels=(
    "  Energy preference — $(epp_now)"
    "  Max frequency — $(cap_now)% · $(ghz "$(cap_now)")"
    "  Dynamic boost — $(flag_now $pstate/hwp_dynamic_boost)"
)

case $(printf '%s\n' "${labels[@]}" | pick --lines ${#labels[@]}) in
    0)
        options=(power balance_power balance_performance performance)
        index=$(choose "$(epp_now)" "${options[@]}") || exit 0
        [ -n "$index" ] || exit 0
        set_epp "${options[$index]}"
        notify "Energy preference" "${options[$index]}"
        ;;
    1)
        options=(40 50 60 70 80 100)
        labels=()
        for pct in "${options[@]}"; do labels+=("$pct% · $(ghz "$pct")"); done
        index=$(choose "$(cap_now)% · $(ghz "$(cap_now)")" "${labels[@]}") || exit 0
        [ -n "$index" ] || exit 0
        set_cap "${options[$index]}"
        notify "Max frequency" "${labels[$index]}"
        ;;
    2)
        index=$(choose "$(flag_now $pstate/hwp_dynamic_boost)" on off) || exit 0
        [ -n "$index" ] || exit 0
        [ "$index" = 0 ] && set_boost on || set_boost off
        notify "Dynamic boost" "$(flag_now $pstate/hwp_dynamic_boost)"
        ;;
    *) exit 0 ;;
esac

save
exec "$0" # back to the top menu, so several settings can be changed in one go
