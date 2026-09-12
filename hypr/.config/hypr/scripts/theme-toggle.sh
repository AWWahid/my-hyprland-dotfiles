#!/usr/bin/env bash
# Toggle global light/dark mode.
# color-scheme is broadcast by xdg-desktop-portal to browsers, Electron and GTK4 apps;
# gtk-theme covers GTK3 apps.
iface=org.gnome.desktop.interface

if [ "$(gsettings get $iface color-scheme)" = "'prefer-dark'" ]; then
    gsettings set $iface color-scheme default
    gsettings set $iface gtk-theme Adwaita
    mode=Light
else
    gsettings set $iface color-scheme prefer-dark
    gsettings set $iface gtk-theme Adwaita-dark
    mode=Dark
fi

notify-send -t 1500 "Theme" "$mode mode"
