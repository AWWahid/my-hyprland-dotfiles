# System info with a picture beside it, chosen in personalize's Terminal pane: ~/.local/share/fastfetch/logo
# links to the wallpaper, a copied picture, or "none" (dangling). No link yet means the wallpaper.
# fastfetch's kitty encoder caches the scaled image; for a GIF it sends every frame and kitty plays them.
function fish_greeting
    type -q fastfetch; or return
    set -l link ~/.local/share/fastfetch/logo
    test -L $link; or set link ~/.local/share/wallpaper/current
    # The resolved path, so fastfetch's cache (keyed by path) never serves the previous picture
    set -l img (realpath -q $link)
    if test "$TERM" = xterm-kitty; and test -f "$img"
        set -l frame 1
        string match -qi '*.gif' -- $img; and set frame 0
        fastfetch --logo $img --logo-type kitty --logo-animation-frame $frame
    else
        fastfetch --logo none
    end
end
