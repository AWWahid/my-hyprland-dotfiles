export PATH="$HOME/.local/bin:$PATH"
# Zed, or nano without a graphical session (~/.local/bin/edit); nothing falls back to vi
export EDITOR=edit VISUAL=edit SUDO_EDITOR=edit

[[ $- != *i* ]] && return
alias ls='ls --color=auto' grep='grep --color=auto'
# user@host in the accent (kitty palette slot 16, set by theme-toggle.sh) so prompts stand out in long output
[ "$TERM" = xterm-kitty ] && PS1='\[\e[1;38;5;16m\]\u@\h\[\e[0m\]:\w> '
