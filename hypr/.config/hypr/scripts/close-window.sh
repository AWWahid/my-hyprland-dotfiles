#!/bin/sh
# SUPER+C. A yazi window gets yazi's own quit, which asks first while a copy or move
# is still running (closing the window would cut it off halfway); anything else closes.
# yazi-window starts yazi with its own PID as client ID, so the window's child is its ID.
pid=$(hyprctl activewindow -j | jq -r .pid)
yazi=$(pgrep -P "$pid" -x yazi) && ya emit-to "$yazi" quit && exit
hyprctl dispatch 'hl.dsp.window.close()'
