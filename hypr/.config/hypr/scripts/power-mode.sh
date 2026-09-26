#!/usr/bin/env bash
# Power menu (click the battery module in waybar). Owns three CPU power knobs and the
# iGPU clock cap outright - TLP no longer sets them (see tlp/01-dotfiles.conf), because it re-applied
# its own values on every resume and every charger event and wiped the choice.
#   waybar:       power-mode.sh          open the menu
#   hyprland.lua: power-mode.sh apply    write the last choice, or the defaults
#
# Writing to /sys needs the video group; tmpfiles/99-cpu-power.conf and
# udev/99-gpu-freq.rules grant it (see CLAUDE.md). Current values are read back from sysfs rather than the state file, so
# the menu can never show something the CPU isn't actually doing.

pstate=/sys/devices/system/cpu/intel_pstate
epps=/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
gpu=$(ls -d /sys/class/drm/card[0-9]*/gt_max_freq_mhz 2>/dev/null | head -1)
gpu=${gpu%/*}
state="${XDG_STATE_HOME:-$HOME/.local/state}/power-mode"

notify() { notify-send -a "Power" "$@"; }
# No search line: every menu is short enough to click, and typing only filtered it
pick() { fuzzel --dmenu --index --hide-prompt "$@"; }

epp_now() { cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference; }
flag_now() { [ "$(cat "$1")" = 1 ] && echo on || echo off; }
cap_now() { cat $pstate/max_perf_pct; }
# A cap as the clock it allows on the fastest core, e.g. 60 -> 2.6 GHz
ghz() { sort -n /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq | tail -1 |
    awk -v pct="$1" '{ printf "%.1f GHz", $1 * pct / 1e8 }'; }

gpu_now() { cat $gpu/gt_max_freq_mhz; }
# Boost is the clock i915 jumps to when an app waits on the GPU, and it ignores the max
# cap, so both are written: one cap that actually holds.
set_gpu() { echo "$1" >$gpu/gt_max_freq_mhz; echo "$1" >$gpu/gt_boost_freq_mhz; }

set_epp() { for f in $epps; do echo "$1" >"$f"; done; }
set_cap() { echo "$1" >$pstate/max_perf_pct; }
set_boost() { [ "$1" = on ] && echo 1 >$pstate/hwp_dynamic_boost || echo 0 >$pstate/hwp_dynamic_boost; }

save() {
    mkdir -p "${state%/*}"
    printf 'epp=%s\ncap=%s\nboost=%s\ngpu=%s\n' \
        "$(epp_now)" "$(cap_now)" "$(flag_now $pstate/hwp_dynamic_boost)" "$(gpu_now)" >"$state"
}

# Battery-first defaults, used until the menu is opened for the first time. This CPU
# (i5-1235U) runs intel_pstate in active mode with HWP, so the governor is only a hint
# and EPP is the real lever. Turbo stays on - base clock alone (1.3 GHz) made the
# desktop feel sluggish - and max_perf_pct caps how far it climbs instead. It is a
# percentage of the top turbo clock (4.4 GHz on the P-cores; the E-cores scale to their
# own 3.3), so 60 stops the P-cores at ~2.6 GHz: enough headroom for page loads and app
# starts, while the top bins, which cost the most power per clock (voltage squared),
# stay out of reach. 30 or below is base clock again, i.e. turbo off.
# The GPU starts uncapped (its top clock, RP0) until a cap is picked in the menu.
defaults() { printf 'epp=power\ncap=60\nboost=off\ngpu=%s\n' "$(cat $gpu/gt_RP0_freq_mhz)"; }

# Write the knobs. Runs at login and again after resume; silent either way.
if [ "$1" = apply ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            epp) set_epp "$value" ;;
            cap) set_cap "$value" ;;
            boost) set_boost "$value" ;;
            gpu) set_gpu "$value" ;;
        esac
    done < <([ -r "$state" ] && cat "$state" || defaults)
    exit 0
fi

# Mark the value that is in effect, so a submenu shows where you are before you change it
mark() { [ "$1" = "$2" ] && printf '  %s  ✓\n' "$1" || printf '  %s\n' "$1"; }

choose() { # choose <current> <value>...
    local current=$1
    shift
    for value in "$@"; do mark "$value" "$current"; done | pick --lines $(($# < 15 ? $# : 15))
}

labels=(
    "  Energy preference — $(epp_now)"
    "  Max frequency — $(cap_now)% · $(ghz "$(cap_now)")"
    "  Dynamic boost — $(flag_now $pstate/hwp_dynamic_boost)"
    "  GPU max frequency — $(gpu_now) MHz"
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
        # ▲/▼ step one 100 MHz clock bin on the fastest core (the finest step the CPU
        # takes; 1% is only 44 MHz and often changes nothing); typing a percentage
        # sets it directly. The entries hold no digits, so typing never matches one.
        bins=$(($(sort -n /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq | tail -1) / 100000))
        min=$(cat $pstate/min_perf_pct)
        while :; do
            cur=$(cap_now)
            bin=$((cur * bins / 100))
            choice=$(printf '  ▲  Up\n  ▼  Down\n' | fuzzel --dmenu --lines 2 --match-mode=exact \
                --prompt "Max frequency $cur% · $(ghz "$cur")  " --placeholder "type $min-100") || exit 0
            case $choice in
                *Up) pct=$((((bin + 1) * 100 + bins - 1) / bins)) ;;
                *Down) pct=$((((bin - 1) * 100 + bins - 1) / bins)) ;;
                *[!0-9]* | '') continue ;;
                *) pct=$((10#$choice)) ;;
            esac
            ((pct > 100)) && pct=100
            ((pct < min)) && pct=$min
            set_cap "$pct"
            save
            case $choice in *Up | *Down) ;; *) break ;; esac
        done
        notify "Max frequency" "$(cap_now)% · $(ghz "$(cap_now)")"
        ;;
    2)
        index=$(choose "$(flag_now $pstate/hwp_dynamic_boost)" on off) || exit 0
        [ -n "$index" ] || exit 0
        [ "$index" = 0 ] && set_boost on || set_boost off
        notify "Dynamic boost" "$(flag_now $pstate/hwp_dynamic_boost)"
        ;;
    3)
        # Same ▲/▼ and typing as the CPU cap, in the 50 MHz steps i915 clocks in
        lo=$(cat $gpu/gt_RPn_freq_mhz) hi=$(cat $gpu/gt_RP0_freq_mhz)
        while :; do
            cur=$(gpu_now)
            choice=$(printf '  ▲  Up\n  ▼  Down\n' | fuzzel --dmenu --lines 2 --match-mode=exact \
                --prompt "GPU max frequency $cur MHz  " --placeholder "type $lo-$hi") || exit 0
            case $choice in
                *Up) mhz=$((cur + 50)) ;;
                *Down) mhz=$((cur - 50)) ;;
                *[!0-9]* | '') continue ;;
                *) mhz=$((10#$choice / 50 * 50)) ;;
            esac
            ((mhz > hi)) && mhz=$hi
            ((mhz < lo)) && mhz=$lo
            set_gpu "$mhz"
            save
            case $choice in *Up | *Down) ;; *) break ;; esac
        done
        notify "GPU max frequency" "$(gpu_now) MHz"
        ;;
    *) exit 0 ;;
esac

save
exec "$0" # back to the top menu, so several settings can be changed in one go
