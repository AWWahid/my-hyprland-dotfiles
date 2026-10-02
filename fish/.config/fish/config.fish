# PATH and EDITOR come from the bash login shell (bash/.bashrc), which starts Hyprland
set -g fish_greeting

# z <fragment> jumps to a frequent folder (history shared with yazi)
if status is-interactive; and type -q zoxide
    zoxide init fish | source
end

# fzf pickers: Ctrl+R history, Ctrl+T file path, Alt+C into a subfolder
if status is-interactive; and type -q fzf
    fzf --fish | source
end
