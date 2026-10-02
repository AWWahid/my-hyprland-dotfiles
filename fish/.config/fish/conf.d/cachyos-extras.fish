# Kept from CachyOS's fish config (cachyos-fish-config), without sourcing the rest of it

# Prompt is Pure (fish-pure-prompt): folder, git, virtualenv and the last command's duration over 5 s
set -g pure_begin_prompt_with_current_directory false

# Notify when a command over 10 s finishes while its terminal is not focused (event-driven)
set -g __done_min_cmd_duration 10000
set -g __done_notification_urgency_level low
test -f /usr/share/cachyos-fish-config/conf.d/done.fish; and source /usr/share/cachyos-fish-config/conf.d/done.fish

# Colored man pages through bat
if type -q bat
    set -gx MANROFFOPT -c
    set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
end

function history
    builtin history --show-time='%F %T ' $argv
end

# eza listings; plain ls stays ls. auto: no colors or icons when piped
if type -q eza
    alias la 'eza -a --color=auto --icons=auto --group-directories-first'
    alias ll 'eza -l --color=auto --icons=auto --group-directories-first'
    alias lt 'eza -aT --color=auto --icons=auto --group-directories-first'
end
