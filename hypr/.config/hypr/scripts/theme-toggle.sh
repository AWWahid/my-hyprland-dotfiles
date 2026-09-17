#!/usr/bin/env bash
# Toggle global light/dark mode, force one with: theme-toggle.sh dark|light,
# or re-apply the current mode (after the personalize panel rewrites ~/.config/hypr/accent.conf) with: theme-toggle.sh apply
# color-scheme is broadcast by xdg-desktop-portal to browsers, Electron and GTK4 apps;
# gtk-theme covers GTK3 apps. Bar/terminal/launcher/notifications swap colors files.
iface=org.gnome.desktop.interface
cfg=~/.config
icons=~/.local/share/icons

mode=$1
dark_now() { [ "$(gsettings get $iface color-scheme)" = "'prefer-dark'" ]; }
case "$mode" in
    dark|light) ;;
    apply) dark_now && mode=dark || mode=light ;;
    *)     dark_now && mode=light || mode=dark ;;
esac

if [ "$mode" = dark ]; then
    gsettings set $iface color-scheme prefer-dark
    gsettings set $iface gtk-theme Adwaita-dark
else
    gsettings set $iface color-scheme default
    gsettings set $iface gtk-theme Adwaita
fi

ln -sfn themes/$mode.css  $cfg/waybar/colors.css
ln -sfn themes/$mode      $cfg/mako/colors
ln -sfn themes/$mode.conf $cfg/kitty/colors.conf

# Accent: generated files (gitignored) so accent.conf stays the single source.
# accent.conf and icons.css are personalize's state (gitignored); defaults on a fresh install
[ -f $cfg/hypr/accent.conf ] || printf 'source=wallpaper\ndark=#33ccff\nlight=#0077b3\n' > $cfg/hypr/accent.conf
[ -L $cfg/waybar/icons.css ] || ln -sfn themes/icons-mono.css $cfg/waybar/icons.css
accent=$(sed -n "s/^$mode=#\?//p" $cfg/hypr/accent.conf)
r=$((16#${accent:0:2})) g=$((16#${accent:2:2})) b=$((16#${accent:4:2}))
(( r * 299 + g * 587 + b * 114 > 150000 )) && on_accent='#000000' || on_accent='#ffffff'

echo "@define-color accent #$accent;" > $cfg/waybar/accent.css

# Yazi: accent on its interface (cwd, tabs, mode, borders, hovered file); file type colors stay on the terminal palette.
# Read at startup, so an open yazi picks it up next launch
{
    echo "[mgr]";       echo "cwd = { fg = \"#$accent\" }"
    echo "[tabs]";      echo "active = { fg = \"$on_accent\", bg = \"#$accent\", bold = true }"; echo "inactive = { fg = \"#$accent\" }"
    echo "[mode]";      echo "normal_main = { fg = \"$on_accent\", bg = \"#$accent\", bold = true }"; echo "normal_alt = { fg = \"#$accent\" }"
    echo "[indicator]"; echo "current = { fg = \"$on_accent\", bg = \"#$accent\" }"; echo "parent = { fg = \"$on_accent\", bg = \"#$accent\" }"
    for section in which confirm spot pick input cmp tasks help; do
        echo "[$section]"; echo "border = { fg = \"#$accent\" }"
    done
} > $cfg/yazi/theme.toml

rm -f $cfg/fuzzel/colors.ini   # was a symlink into themes/; don't write through it
# Selection matches waybar's active style: accent at 15% (0x26) behind normal text
{ cat $cfg/fuzzel/themes/$mode.ini; echo "match=${accent}ff"; echo "selection=${accent}26"; echo "selection-match=${accent}ff"; } > $cfg/fuzzel/colors.ini

for gtk in gtk-3.0 gtk-4.0; do
    rm -f $cfg/$gtk/gtk.css
    cat > $cfg/$gtk/gtk.css <<EOF
@import url("themes/$mode.css");
@define-color accent_color #$accent;
@define-color accent_bg_color #$accent;
@define-color accent_fg_color $on_accent;
@define-color theme_selected_bg_color #$accent;
@define-color theme_selected_fg_color $on_accent;
EOF
done

# Busy-cursor spinner. index.theme records the accent it was built with, so re-picking the same
# color is free; personalize rewrites accent.conf every time, which is why mtime won't do.
theme=macOS-accent-$mode
index=$icons/$theme/index.theme
gen=$HOME/.local/bin/accent-cursors
[ -x "$gen" ] || gen=$(command -v accent-cursors)
if [ ! -x "$gen" ]; then
    echo "theme-toggle: accent-cursors not installed (cargo install --path ~/dotfiles/accent-cursors --root ~/.local); keeping existing cursors" >&2
elif [ "$(sed -n 's/^accent=#\?//p' "$index" 2>/dev/null)" != "$accent" ] || [ "$gen" -nt "$index" ]; then
    rm -rf $icons/$theme
    "$gen" "$accent" $mode $icons/$theme
fi
ln -sfn $theme $icons/macOS-accent   # stable name for XCURSOR_THEME at login
gsettings set $iface cursor-theme $theme
hyprctl setcursor macOS 28 >/dev/null   # Hyprland skips reloading an already-loaded theme name
hyprctl setcursor $theme 28 >/dev/null

pkill -USR2 -x waybar   # reload style
pkill -USR1 -x kitty    # reload config
makoctl reload

