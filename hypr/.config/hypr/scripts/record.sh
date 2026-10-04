#!/usr/bin/env bash
# Screen recording (Ctrl+Print). gpu-screen-recorder (NVIDIA: NVENC) or else wl-screenrec (VA-API)
# encodes on the GPU, so frames never touch the CPU. Nothing runs while not recording.
#   no argument: menu, or stop if a recording is running
#   status:      waybar JSON (red dot while recording, empty text hides the module)
#   stop:        end the recording
# gpu-screen-recorder: AV1 in MP4, and it mixes mic and system audio itself.
# wl-screenrec: VP9 in WebM: openSUSE's ffmpeg ships no H.264/HEVC encoders (patents), and VP9 is
# the one modern codec left that the Iris Xe encodes in hardware.
# Needs gpu-screen-recorder or wl-screenrec, slurp, jq, ffmpeg (thumbnail), pactl (mixed audio,
# wl-screenrec only) and mpv.

run="${XDG_RUNTIME_DIR:-/tmp}/record"
pidfile="$run.pid"
state="${XDG_STATE_HOME:-$HOME/.local/state}/record-sound"
dir="$(xdg-user-dir VIDEOS 2>/dev/null || echo "$HOME/Videos")/Screen Recordings"

refresh() { pkill -RTMIN+10 -x waybar; }
recording() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
pick() { fuzzel --dmenu --index --hide-prompt "$@"; }

case "$1" in
    status)
        recording && echo '{"text":"","class":"on","tooltip":"Recording · click to stop"}' || echo '{"text":""}'
        exit ;;
    stop)
        recording && kill -INT "$(cat "$pidfile")"
        exit ;;
esac
recording && exec "$0" stop

sounds=("No sound" "Microphone" "System audio" "Microphone + system audio")
sound=$(cat "$state" 2>/dev/null || echo 0)

# Main menu; the sound entry opens its own list and comes back, like power-mode.sh
while :; do
    choice=$(printf '%s\n' "  Record screen" "  Record region" "  Record window" \
        "  Sound — ${sounds[$sound]}" | pick --lines 4) || exit 0
    [ "$choice" = 3 ] || break
    new=$(for i in "${!sounds[@]}"; do
        [ "$i" = "$sound" ] && echo "  ${sounds[$i]}  ✓" || echo "  ${sounds[$i]}"
    done | pick --lines 4) || continue
    sound=$new
    mkdir -p "${state%/*}" && echo "$sound" >"$state"
done

case "$choice" in
    0) g= ;;
    1) g=$(slurp) || exit 0 ;;
    2)  # windows on the visible workspaces as click targets; the rectangle is fixed once chosen
        ws=$(hyprctl monitors -j | jq -r '[.[].activeWorkspace.id]')
        g=$(hyprctl clients -j | jq -r --argjson ws "$ws" \
            '.[] | select(.workspace.id as $w | $ws | index($w)) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' |
            slurp -r) || exit 0 ;;
    *) exit 0 ;;
esac

mkdir -p "$dir"
name="$dir/Screen Recording $(date '+%Y-%m-%d at %H.%M.%S')"
modules=()

if command -v gpu-screen-recorder >/dev/null; then
    # Not wl-screenrec here: VA-API on NVIDIA is unreliable. Capture is KMS, where -fm content
    # is unavailable, so recordings are VFR.
    # slurp gives "X,Y WxH"; gpu-screen-recorder wants WxH+X+Y
    if [ -n "$g" ]; then
        read -r xy wh <<<"$g"
        area=(-w region -region "$wh+${xy/,/+}")
    else
        area=(-w "$(hyprctl monitors -j | jq -r '.[] | select(.focused).name')")
    fi
    case "$sound" in
        1) audio=(-a default_input) ;;
        2) audio=(-a default_output) ;;
        3) audio=(-a "default_output|default_input") ;;
        *) audio=() ;;
    esac
    file="$name.mp4"
    gpu-screen-recorder "${area[@]}" -k av1 "${audio[@]}" -o "$file" &
else
    area=(); [ -n "$g" ] && area=(-g "$g")
    # Mixed sound: a temporary null sink fed by the mic and by whatever is playing, torn down on stop
    # so nothing keeps the audio device awake afterwards. The @DEFAULT_*@ names follow a device switch.
    case "$sound" in
        1) audio=(--audio --audio-device @DEFAULT_SOURCE@) ;;
        2) audio=(--audio --audio-device @DEFAULT_MONITOR@) ;;
        3)
            modules+=("$(pactl load-module module-null-sink sink_name=record-mix sink_properties=device.description=Recording)")
            modules+=("$(pactl load-module module-loopback source=@DEFAULT_SOURCE@ sink=record-mix latency_msec=20)")
            modules+=("$(pactl load-module module-loopback source=@DEFAULT_MONITOR@ sink=record-mix latency_msec=20)")
            audio=(--audio --audio-device record-mix.monitor) ;;
        *) audio=() ;;
    esac

    file="$name.webm"
    wl-screenrec --codec vp9 "${area[@]}" "${audio[@]}" -f "$file" &
fi
echo $! >"$pidfile"
refresh
wait
rm -f "$pidfile"
for m in "${modules[@]}"; do pactl unload-module "$m"; done
refresh

[ -s "$file" ] || exit
preview="$run-preview.png"
ffmpeg -loglevel error -y -i "$file" -frames:v 1 -vf scale=520:-1 "$preview"
action=$(notify-send -a Recording -h "string:image-path:$preview" \
    --action=default=Play "Recording saved — click to play")
[ "$action" = default ] && mpv "$file"
