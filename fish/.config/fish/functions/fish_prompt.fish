# user@host in the accent (kitty palette slot 16, set by theme-toggle.sh), same as the bash prompt
function fish_prompt
    printf '\e[1;38;5;16m%s@%s\e[0m:%s> ' $USER (prompt_hostname) (string replace -r "^$HOME" '~' -- $PWD)
end
