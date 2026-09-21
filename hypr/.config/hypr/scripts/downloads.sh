#!/usr/bin/env bash
# Open Varia, and notify when a download finishes.
#
# Varia has no download-completed notification of its own, so we ask its aria2 instead of
# watching folders: aria2 pushes an "aria2.onDownloadComplete" notification over its JSON-RPC
# WebSocket, which covers every download wherever it is saved, with no folder list to maintain
# and nothing polling. curl speaks ws:// natively and the rest is jq and python3, already here,
# with nothing new to install. The API is aria2's, not Varia's, and has been
# stable since 2013; the only Varia-specific part is where to connect, which is read from
# varia.conf below rather than hardcoded, so remote mode and a changed port follow along.
# The watcher starts with Varia and is killed with it.
app=io.github.giantpinkrobots.varia
conf=$HOME/.var/app/$app/data/varia.conf

# Where Varia's aria2 listens. Local mode is a fixed localhost:6801 with no secret (initiate.py);
# remote mode puts the address in the config.
read -r host secret < <(jq -r '
    if .remote == "1"
    then (.remote_protocol + .remote_ip + ":" + .remote_port) + " " + (.remote_secret + "\u0000")
    else "http://localhost:6801 \u0000"
    end' "$conf" 2>/dev/null)
host=${host:-http://localhost:6801}
secret=${secret%$'\0'}

# aria2 takes the secret as a "token:" first parameter, and only when one is set.
rpc() {  # method, params-json-array
    local params=$2
    [ -n "$secret" ] && params=$(jq -c --arg t "token:$secret" '[$t] + .' <<<"$params")
    curl -s --max-time 5 -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"v\",\"method\":\"$1\",\"params\":$params}" "$host/jsonrpc"
}

if [ "$1" = watch ]; then
    # aria2 comes up a moment after Varia does
    for _ in $(seq 30); do
        rpc aria2.getVersion '[]' | grep -q result && break
        sleep 1
    done

    ws=ws${host#http}   # http -> ws, https -> wss
    # aria2 sends its notifications back-to-back with no separator, and jq buffers its input, so
    # it emits nothing until the connection closes. Python's decoder is fed each chunk as it
    # arrives and hands over one gid per line, which is what makes this actually live.
    curl -sN "$ws/jsonrpc" | python3 -u -c '
import sys, json
dec = json.JSONDecoder(); buf = ""
while True:
    chunk = sys.stdin.buffer.read1(65536)
    if not chunk:
        break
    buf += chunk.decode()
    while buf.strip():
        buf = buf.lstrip()
        try:
            obj, end = dec.raw_decode(buf)
        except ValueError:
            break
        buf = buf[end:]
        if obj.get("method") in ("aria2.onDownloadComplete", "aria2.onBtDownloadComplete"):
            print(obj["params"][0]["gid"], flush=True)
' |
    while read -r gid; do
        # a torrent is a folder of files, so it is named by the torrent rather than by a file
        name=$(rpc aria2.tellStatus "[\"$gid\",[\"files\",\"bittorrent\"]]" |
            jq -r '.result | (.bittorrent.info.name // (.files[0].path | split("/") | last)) // empty')
        [ -n "$name" ] && notify-send -a Varia -i "$app" "Download complete" "$name"
    done
    exit
fi

# Already open: raise it instead of starting a second watcher
pgrep -f "$app" >/dev/null && exec flatpak run "$app"

# setsid so the watcher leads its own process group and the whole pipeline dies with Varia
setsid "$0" watch >/dev/null 2>&1 &
watcher=$!
trap 'kill -- -"$watcher" 2>/dev/null' EXIT
flatpak run "$app"
