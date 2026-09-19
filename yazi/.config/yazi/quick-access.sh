#!/usr/bin/env bash
# Rebuilds yazi's Quick Access start folder: symlinks to Home, pinned folders (yamb),
# frequent folders (zoxide), drives with their free space, and Trash. Run by plugins/explorer.yazi
# at startup and whenever yazi enters the folder, never in the background.
# Only ever deletes the symlinks inside that folder, never what they point to.
set -u
state=${XDG_STATE_HOME:-$HOME/.local/state}/yazi
qa=$state/quick-access
pins=$state/bookmarks
frequent=6

mkdir -p "$qa"
# Startup and entering the folder can overlap; one build at a time
exec 9>"$state/quick-access.lock"
flock 9
chmod 755 "$qa"
find "$qa" -mindepth 1 -maxdepth 1 -type l -delete

# yazi sorts by name, so each name starts with a glyph whose code point puts its group in place:
# Home < pinned < frequent < disks < USB < network < Trash (alphabetical inside each group)
home=$'\uf015' pin=$'\uf08d' recent=$'\uf1da'
disk=$'\U000f02ca' usb=$'\U000f0553' net=$'\U000f08f3' bin=$'\U000f0a79'

link() { ln -s -- "$2" "$qa/${1//\//∕}" 2>/dev/null; } # name target; a clashing name is skipped
declare -A taken
add() { # glyph label target: each folder once across Home, pins and frequent
    [ -n "${taken[$3]:-}" ] && return
    link "$1 $2" "$3" && taken[$3]=1
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
            "$HOME" | / | "$state"/* | "${XDG_DATA_HOME:-$HOME/.local/share}"/Trash*) continue ;;
        esac
        [ -d "$dir" ] && [ -z "${taken[$dir]:-}" ] || continue
        add "$recent" "$(basename "$dir")" "$dir"
        count=$((count + 1))
    done < <(zoxide query --list 2>/dev/null)
fi

# Drives: / plus mounts under /mnt, /media and /run/media (udisks: /run/media/$USER on Fedora, Arch and
# openSUSE, /media/$USER on Debian and Ubuntu). findmnt escapes spaces as \x20; LABEL is last so an
# empty one is just a missing field. A drive can appear twice: its autofs placeholder (fstab
# x-systemd.automount), which opening mounts, and the real mount, which wins.
declare -A fstype opts label
order=()
while read -r t f o l; do
    t=$(printf '%b' "$t")
    case $t in / | /mnt/?* | /media/?* | /run/media/?*) ;; *) continue ;; esac
    [ -z "${fstype[$t]:-}" ] && order+=("$t")
    [ "$f" = autofs ] && [ -n "${fstype[$t]:-}" ] && continue
    fstype[$t]=$f opts[$t]=$o label[$t]=$(printf '%b' "${l:-}")
done < <(findmnt -rn -o TARGET,FSTYPE,OPTIONS,LABEL)

# Sizes in SI units like GNOME and Windows
H='function h(b, i) { split("B kB MB GB TB PB", u, " "); i = 1; while (b >= 1000 && i < 6) { b /= 1000; i++ }
                     return sprintf(b < 10 && i > 1 ? "%.1f %s" : "%.0f %s", b, u[i]) }'
info() { # size avail readonly -> "▰▰▰▱▱▱▱▱▱▱  120 GB free of 237 GB" (10-cell usage bar)
    awk -v s="$1" -v a="$2" -v ro="$3" "$H"'
        BEGIN {
            if (s <= 0) { if (ro) print "read-only"; exit }
            c = int((s - a) * 10 / s + 0.5); if (s > a && c < 1) c = 1
            for (i = 1; i <= 10; i++) bar = bar (i <= c ? "▰" : "▱")
            print bar "  " (ro ? h(s) ", read-only" : h(a) " free of " h(s))
        }'
}

declare -A seen
names=() infos=() glyphs=() targets=() width=0
for t in "${order[@]}"; do
    f=${fstype[$t]:-}
    [ -z "$f" ] && continue
    case $f in
        nfs* | cifs | smb* | fuse.sshfs | fuse.rclone | davfs | 9p | afs | ceph | glusterfs) g=$net ;;
        *) case $t in /run/media/* | /media/*) g=$usb ;; *) g=$disk ;; esac ;;
    esac
    ro=0
    [[ ,${opts[$t]}, == *,ro,* ]] && ro=1
    size=0 avail=0 text=
    if [ "$f" = autofs ]; then
        text="not mounted" # statting it would mount the drive
    else
        # A dead network share hangs statfs; list it without sizes instead of hanging
        read -r size avail < <(timeout 2 df -Pk -- "$t" 2>/dev/null | awk 'NR == 2 { print $2 * 1024, $4 * 1024 }')
        text=$(info "${size:-0}" "${avail:-0}" $ro)
    fi
    l=${label[$t]}
    [ "$t" = / ] && l=System
    if [ -z "$l" ]; then
        # Like Nautilus: "500 GB Volume" for a disk, else the mount folder's name
        [ "$g" != "$net" ] && [ "${size:-0}" -gt 0 ] && l="$(awk -v s="$size" "$H"' BEGIN { print h(s) }') Volume" || l=$(basename "$t")
    fi
    (( ${#l} > 24 )) && l="${l:0:23}…"
    seen[$l]=$(( ${seen[$l]:-0} + 1 ))
    (( ${seen[$l]} > 1 )) && l="$l (${seen[$l]})"
    (( ${#l} > width )) && width=${#l}
    names+=("$l") infos+=("$text") glyphs+=("$g") targets+=("$t")
done
# Pad labels so the bars line up
for i in "${!names[@]}"; do
    name="${glyphs[$i]} ${names[$i]}"
    [ -n "${infos[$i]}" ] && name+="$(printf '%*s' $((width - ${#names[$i]})) '')  ${infos[$i]}"
    link "$name" "${targets[$i]}"
done

# Points at an empty read-only placeholder that explorer.yazi opens as trash://. Never at the raw
# Trash folder: deleting in there directly would orphan its restore records
trash=$state/trash-shortcut
mkdir -p "$trash" && chmod 555 "$trash"
link "$bin Trash" "$trash"

chmod 555 "$qa"
