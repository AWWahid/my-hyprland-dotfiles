# cachy-update hides paru's AUR warnings (orphaned, out of date, gone from the AUR)
# unless an AUR update is pending, so show them before every update
function cachy-update --wraps cachy-update
    if type -q paru; and not paru -Qua >/dev/null 2>&1
        paru -Sua </dev/null 2>/dev/null | string match -r '^:: (?:orphans|marked out of date|packages not in the AUR): .*'
    end
    command cachy-update $argv
end
