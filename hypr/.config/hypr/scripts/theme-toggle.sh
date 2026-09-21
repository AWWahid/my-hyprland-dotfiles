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

# Accent: generated files (gitignored) so accent.conf stays the single source.
# accent.conf, icons.css, bar.css and hover.css are personalize's state (gitignored); defaults on a fresh install
[ -f $cfg/hypr/accent.conf ] || printf 'source=wallpaper\ndark=#33ccff\nlight=#0077b3\n' > $cfg/hypr/accent.conf
[ -L $cfg/waybar/icons.css ] || ln -sfn themes/icons-mono.css $cfg/waybar/icons.css
[ -L $cfg/waybar/bar.css ] || ln -sfn themes/bar-translucent.css $cfg/waybar/bar.css
[ -L $cfg/waybar/hover.css ] || ln -sfn themes/hover-pill.css $cfg/waybar/hover.css
accent=$(sed -n "s/^$mode=#\?//p" $cfg/hypr/accent.conf)
r=$((16#${accent:0:2})) g=$((16#${accent:2:2})) b=$((16#${accent:4:2}))
(( r * 299 + g * 587 + b * 114 > 150000 )) && on_accent='#000000' || on_accent='#ffffff'

echo "@define-color accent #$accent;" > $cfg/waybar/accent.css
# Kitty: accent in palette slot 16 (the bash prompt's user@host), so open terminals follow it on reload.
# rm first: this used to be a symlink into themes/, and writing through it would overwrite the theme.
rm -f $cfg/kitty/colors.conf
{ cat $cfg/kitty/themes/$mode.conf; echo "color16 #$accent"; } > $cfg/kitty/colors.conf

# Yazi: accent on its interface (cwd, tabs, mode, borders); file names colored by kind of file:
# folders amber, images magenta, audio/video purple, archives red, executables green, the rest plain text.
# Read at startup, so an open yazi picks it up next launch
if [ "$mode" = dark ]; then
    folder='#e0a53c' image='#d884e0' media='#a48cf2' archive='#ef6f6c' exec='#8fcf6a'
else
    folder='#a86f00' image='#a4329f' media='#6b4fc8' archive='#c62828' exec='#2e7d32'
fi
{
    echo "[mgr]";       echo "cwd = { fg = \"#$accent\" }"
    echo "[tabs]";      echo "active = { fg = \"$on_accent\", bg = \"#$accent\", bold = true }"; echo "inactive = { fg = \"#$accent\" }"
    echo "[mode]";      echo "normal_main = { fg = \"$on_accent\", bg = \"#$accent\", bold = true }"; echo "normal_alt = { fg = \"#$accent\" }"
    echo "[indicator]"; echo "current = { fg = \"$on_accent\", bg = \"#$accent\" }"; echo "parent = { fg = \"$on_accent\", bg = \"#$accent\" }"
    for section in which confirm spot pick input cmp tasks help; do
        echo "[$section]"; echo "border = { fg = \"#$accent\" }"
    done
    cat <<EOF
[filetype]
rules = [
    { url = "*", is = "orphan", bg = "red" },
    { url = "*", is = "dummy", bg = "red" },
    { url = "*/", is = "dummy", bg = "red" },
    { mime = "vfs/{absent,stale}", fg = "gray" },
    { url = "*/", fg = "$folder" },
    { mime = "**/image/*", fg = "$image" },
    { mime = "**/{audio,video}/*", fg = "$media" },
    { mime = "**/application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}", fg = "$archive" },
    { url = "*", is = "exec", fg = "$exec" },
]
EOF
    cat $cfg/yazi/icons.toml
} > $cfg/yazi/theme.toml

rm -f $cfg/fuzzel/colors.ini   # was a symlink into themes/; don't write through it
# Selection matches waybar's active style: accent at 15% (0x26) behind normal text
{ cat $cfg/fuzzel/themes/$mode.ini; echo "match=${accent}ff"; echo "selection=${accent}26"; echo "selection-match=${accent}ff"; } > $cfg/fuzzel/colors.ini

# btop: accent on the highlights and the selected row; the semantic gradients
# (temperature, load, network) stay fixed. Read at startup, so an open btop picks it up next launch
rm -f $cfg/btop/themes/accent.theme
{
    cat $cfg/btop/themes/$mode.theme
    echo "theme[hi_fg]=\"#$accent\""
    echo "theme[selected_bg]=\"#$accent\""
    echo "theme[selected_fg]=\"$on_accent\""
} > $cfg/btop/themes/accent.theme

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

# Firefox (not stowed): both modes' accents, since it switches light/dark live from the portal.
# userChrome.css is read at startup, so a new accent shows after Firefox restarts
fx=$(dirname "$(readlink -f "$0")")/../../../../firefox/chrome/colors.css
for m in dark light; do
    a=$(sed -n "s/^$m=#\\?//p" $cfg/hypr/accent.conf)
    (( 16#${a:0:2} * 299 + 16#${a:2:2} * 587 + 16#${a:4:2} * 114 > 150000 )) && fg='#000000' || fg='#ffffff'
    [ $m = dark ] && echo '@media (prefers-color-scheme: dark) {' || echo '@media not (prefers-color-scheme: dark) {'
    echo "  :root { --sys-accent: #$a !important; --sys-on-accent: $fg !important; }"
    echo '}'
done > "$fx"

# Obsidian (not stowed; the snippet lives in the vault, which is its own git repo).
# Electron follows the portal for light/dark, so like Firefox this carries both modes' colours
# and no regeneration is needed to switch. Themes are free to hardcode the accent as literal
# hex (Apple Notes does), so setting --accent-h/s/l alone is not enough: the vars derived from
# it have to be set too. Backgrounds are the system's own black/white rather than the theme's,
# so Obsidian matches kitty and the bar: one flat black (or white) everywhere, with the
# borders carrying the structure, exactly as gtk-3.0/themes/dark.css does it - no tinted
# sidebar, since theme_bg_color and theme_base_color are both pure black there.
# No transparency: Obsidian gates it on
# process.platform === "darwin", so the window has no alpha channel on Linux at all.
hex_hsl() {   # RRGGBB -> "H S L" (hue in degrees, the other two in percent)
    local r=$((16#${1:0:2})) g=$((16#${1:2:2})) b=$((16#${1:4:2})) max min d l s=0 h=0
    max=$r; min=$r
    if (( g > max )); then max=$g; fi
    if (( b > max )); then max=$b; fi
    if (( g < min )); then min=$g; fi
    if (( b < min )); then min=$b; fi
    d=$((max - min)); l=$(( (max + min) * 100 / 510 ))
    if (( d )); then
        if (( max + min <= 255 )); then s=$(( d * 100 / (max + min) ))
        else                           s=$(( d * 100 / (510 - max - min) )); fi
        if   (( max == r )); then h=$(( ( (g - b) * 60 / d + 360 ) % 360 ))
        elif (( max == g )); then h=$(( (b - r) * 60 / d + 120 ))
        else                       h=$(( (r - g) * 60 / d + 240 )); fi
    fi
    echo "$h $s $l"
}

obs_json=$cfg/obsidian/obsidian.json
obs_ui=$(dirname "$(readlink -f "$0")")/../../../../obsidian/ui.css
if [ -f "$obs_json" ] && [ -f "$obs_ui" ]; then
    obs_css=$(
        for m in dark light; do
            # bg/fg/muted are waybar's themes/$m.css, the system's source of truth for these
            if [ "$m" = dark ]; then
                bg='#000000' fg='#e6e6e6' muted='#808080' faint='#595959'
                border='#262626' hover='rgba(255, 255, 255, 0.06)'
            else
                bg='#ffffff' fg='#1a1a1a' muted='#7a7a7a' faint='#a1a1a1'
                border='#dcdcdc' hover='rgba(0, 0, 0, 0.05)'
            fi
            a=$(sed -n "s/^$m=#\?//p" $cfg/hypr/accent.conf)
            ar=$((16#${a:0:2})) ag=$((16#${a:2:2})) ab=$((16#${a:4:2}))
            (( ar * 299 + ag * 587 + ab * 114 > 150000 )) && on='#000000' || on='#ffffff'
            read -r h sa l <<< "$(hex_hsl "$a")"
            cat <<EOF
body.theme-$m {
  --accent-h: $h;
  --accent-s: $sa%;
  --accent-l: $l%;
  --color-accent: #$a;
  --color-accent-1: #$a;
  --color-accent-2: #$a;
  --interactive-accent: #$a;
  --interactive-accent-hover: #$a;
  --text-accent: #$a;
  --text-accent-hover: #$a;
  --text-on-accent: $on;
  --text-selection: rgba($ar, $ag, $ab, 0.28);
  --background-modifier-active-hover: rgba($ar, $ag, $ab, 0.18);

  --background-primary: $bg;
  --background-primary-alt: $bg;
  --background-secondary: $bg;
  --background-secondary-alt: $bg;
  --background-modifier-form-field: $bg;
  --titlebar-background: $bg;
  --titlebar-background-focused: $bg;
  --tab-background-active: $bg;
  --tab-background: $bg;
  --ribbon-background: $bg;
  --ribbon-background-collapsed: $bg;
  --status-bar-background: $bg;
  --modal-background: $bg;
  --prompt-bg: $bg;
  --background-modifier-border: $border;
  --background-modifier-border-hover: $border;
  --background-modifier-hover: $hover;
  --divider-color: $border;
  --text-normal: $fg;
  --text-muted: $muted;
  --text-faint: $faint;
}
EOF
        done
        cat "$obs_ui"
    )
    # One vault per "path" key; write to each that still exists on disk.
    grep -o '"path":"[^"]*"' "$obs_json" | cut -d'"' -f4 | while read -r vault; do
        [ -d "$vault/.obsidian" ] || continue
        mkdir -p "$vault/.obsidian/snippets"
        printf '/* Generated by theme-toggle.sh from ~/.config/hypr/accent.conf - do not edit. */\n%s\n' \
            "$obs_css" > "$vault/.obsidian/snippets/dotfiles.css"
    done
fi

# Tray icons: apps that ship a full-color logo look foreign among the bar's flat glyphs.
# $XDG_DATA_HOME/icons outranks the Flatpak exports, so a monochrome copy under the app's own
# icon name shadows it. Add an `apps/<icon-name>.svg` line here for any future offender.
trayicons=$icons/hicolor/scalable/apps
mkdir -p $trayicons
for name in io.github.giantpinkrobots.varia; do
    cat > $trayicons/$name.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
<path fill="#$accent" d="M11 3h2v8.2l3.1-3.1 1.4 1.4-5.5 5.5-5.5-5.5 1.4-1.4L11 11.2V3z"/>
<path fill="#$accent" d="M4 18h16v2.5H4z"/>
</svg>
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

