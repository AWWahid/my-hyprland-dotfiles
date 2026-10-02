[[ -f ~/.bashrc ]] && . ~/.bashrc
# Hyprland on tty1 login; other ttys stay plain shells
[ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ] && exec start-hyprland
