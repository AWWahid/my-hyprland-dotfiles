#!/usr/bin/env bash
# Clipboard history (cliphist) in fuzzel; the first item empties the history, the clipboard itself
# and the files copied in any open yazi.
list=$(cliphist list)
i=$(printf '%s\n%s' "Clear clipboard" "$list" | fuzzel --dmenu --index) || exit
if [ "$i" -eq 0 ]; then
    cliphist wipe
    wl-copy --clear
    ya pub-to 0 clipboard-clear --json null 2>/dev/null
else
    sed -n "${i}p" <<<"$list" | cliphist decode | wl-copy
fi
