#!/usr/bin/env bash
# Links user.js, chrome/userChrome.css and chrome/colors.css (made by theme-toggle.sh) into the Firefox profile in use. Not a stow package: the
# profile folder has a random name and sits in a different place for native Firefox and the Flatpak.
# Run once per machine after Firefox has started once (that creates the profile); rerun after
# creating a new profile. Existing files of the same name are moved aside to *.bak, never deleted
set -eu
repo=$(cd "$(dirname "$0")" && pwd)
found=0
for ini in ~/.mozilla/firefox/profiles.ini \
           "${XDG_CONFIG_HOME:-$HOME/.config}"/mozilla/firefox/profiles.ini \
           ~/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini \
           ~/.var/app/org.mozilla.firefox/config/mozilla/firefox/profiles.ini; do
    [ -f "$ini" ] || continue
    # The profile this Firefox install opens ([Install…] Default=), else the one marked Default=1
    rel=$(awk -F= '/^\[Install/ { i = 1; next } /^\[/ { i = 0 } i && $1 == "Default" { print $2; exit }' "$ini")
    [ -n "$rel" ] || rel=$(awk -F= '/^\[/ { p = "" } $1 == "Path" { p = $2 } $1 == "Default" && $2 == 1 && p { print p; exit }' "$ini")
    [ -n "$rel" ] || continue
    case $rel in /*) dir=$rel ;; *) dir=$(dirname "$ini")/$rel ;; esac
    [ -d "$dir" ] || continue
    [ -L "$dir/chrome" ] && rm -- "$dir/chrome" # a folder link left by the old stow package
    mkdir -p "$dir/chrome"
    for f in user.js chrome/userChrome.css chrome/colors.css; do
        [ -e "$dir/$f" ] && [ ! -L "$dir/$f" ] && mv -- "$dir/$f" "$dir/$f.bak"
        ln -sfn -- "$repo/$f" "$dir/$f"
    done
    # The Flatpak only sees granted folders; the links point into the repo
    case $ini in */.var/app/*) flatpak override --user --filesystem="${repo/#$HOME/\~}:ro" org.mozilla.firefox ;; esac
    echo "Linked into $dir"
    found=1
done
[ $found = 1 ] || { echo "No Firefox profile found; start Firefox once, then rerun" >&2; exit 1; }
echo "Restart Firefox to apply"
