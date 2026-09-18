#!/usr/bin/env bash
# Rebuilds yazi's Quick Access start folder: symlinks to Home, pinned folders (yamb),
# frequent folders (zoxide), mounted drives and Trash. Run on launch and whenever
# yazi enters the folder (plugins/explorer.yazi), never in the background.
# Only ever deletes the symlinks inside that folder, never what they point to.
set -u
qa=${XDG_STATE_HOME:-$HOME/.local/state}/yazi/quick-access
pins=${XDG_STATE_HOME:-$HOME/.local/state}/yazi/bookmarks
frequent=6

mkdir -p "$qa"
chmod 755 "$qa"
find "$qa" -mindepth 1 -maxdepth 1 -type l -delete

# Order comes from the leading glyph: yazi sorts by name, and these glyphs' code points go
# Home < pinned < frequent < drives < Trash (pinned, frequent and drives are alphabetical inside)
home=$'\uf015' pin=$'\uf08d' recent=$'\uf1da' disk=$'\U000f02ca' usb=$'\U000f129e' bin=$'\U000f0a79'
declare -A taken_name taken_target
add() { # glyph label target
    local label=${2//\//∕} target=$3 name
    [ -n "${taken_target[$target]:-}" ] && return
    name="$1 $label"
    # two folders with the same name: tell them apart by their parent
    [ -n "${taken_name[$name]:-}" ] && name="$1 $label ($(basename "$(dirname "$target")"))"
    [ -n "${taken_name[$name]:-}" ] && return
    ln -s -- "$target" "$qa/$name" || return
    taken_name[$name]=1 taken_target[$target]=1
}

add "$home" Home "$HOME"

# yamb's bookmark file: tag<TAB>path<TAB>key, folders end in /
if [ -f "$pins" ]; then
    while IFS=$'\t' read -r tag path _; do
        path=${path%/}
        [ -n "$path" ] && [ -d "$path" ] && add "$pin" "$tag" "$path"
    done < "$pins"
fi

if command -v zoxide >/dev/null; then
    count=0
    while IFS= read -r dir && [ $count -lt $frequent ]; do
        case $dir in
            "$HOME" | / | "$qa" | "$qa"/* | "$HOME"/.local/share/Trash*) continue ;;
        esac
        [ -d "$dir" ] && [ -z "${taken_target[$dir]:-}" ] || continue
        add "$recent" "$(basename "$dir")" "$dir"
        count=$((count + 1))
    done < <(zoxide query --list 2>/dev/null)
fi

add "$disk" System /
# Mounted drives only; USB sticks land in /run/media/$USER. findmnt escapes spaces as \x20.
# Real mounts first so they win over their autofs placeholder (fstab x-systemd.automount), which
# still lists a drive that isn't mounted yet: opening it mounts it
while read -r _ target label; do
    target=$(printf '%b' "$target") label=$(printf '%b' "$label")
    case $target in
        /run/media/*) add "$usb" "${label:-$(basename "$target")}" "$target" ;;
        /mnt/* | /media/*) add "$disk" "${label:-$(basename "$target")}" "$target" ;;
    esac
done < <(findmnt -rn -o FSTYPE,TARGET,LABEL | awk '{ print ($1 == "autofs"), $2, $3 }' | sort -s -n -k1,1)

# Points at an empty read-only placeholder that explorer.yazi opens as trash://. Never at the raw
# Trash folder: deleting in there directly would orphan its restore records
trash=${qa%/*}/trash-shortcut
mkdir -p "$trash" && chmod 555 "$trash"
add "$bin" Trash "$trash"

chmod 555 "$qa"
