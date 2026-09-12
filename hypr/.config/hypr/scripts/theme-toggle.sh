#!/usr/bin/env bash
# Toggle global light/dark mode, or force one with: theme-toggle.sh dark|light
# color-scheme is broadcast by xdg-desktop-portal to browsers, Electron and GTK4 apps;
# gtk-theme covers GTK3 apps. Bar/terminal/launcher/notifications swap colors files.
iface=org.gnome.desktop.interface
cfg=~/.config

mode=$1
if [ -z "$mode" ]; then
    [ "$(gsettings get $iface color-scheme)" = "'prefer-dark'" ] && mode=light || mode=dark
fi

if [ "$mode" = dark ]; then
    gsettings set $iface color-scheme prefer-dark
    gsettings set $iface gtk-theme Adwaita-dark
else
    gsettings set $iface color-scheme default
    gsettings set $iface gtk-theme Adwaita
fi

ln -sfn themes/$mode.css  $cfg/waybar/colors.css
ln -sfn themes/$mode.ini  $cfg/fuzzel/colors.ini
ln -sfn themes/$mode      $cfg/mako/colors
ln -sfn themes/$mode.conf $cfg/kitty/colors.conf
ln -sfn themes/$mode.css  $cfg/gtk-3.0/gtk.css
ln -sfn themes/$mode.css  $cfg/gtk-4.0/gtk.css

pkill -USR2 -x waybar   # reload style
pkill -USR1 -x kitty    # reload config
makoctl reload

notify-send -t 1500 "Theme" "${mode^} mode"
