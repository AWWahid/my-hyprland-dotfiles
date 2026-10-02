# Overrides Pure's (fish-pure-prompt) ssh-only segment: user@host always leads the first line,
# in the accent (kitty palette slot 16, set by theme-toggle.sh), same as the bash prompt
function _pure_prompt_ssh
    printf '\e[1;38;5;16m%s@%s\e[0m' $USER (prompt_hostname)
end
