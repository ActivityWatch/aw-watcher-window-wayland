# Helpers shared by the tests that exercise the shipped systemd unit.
# Source it after `cd`-ing to the repository root.

unit=aw-watcher-window-wayland.service

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# extract_exec_start_pre PATTERN
#
# Sets $shell and $expr to the interpreter and script of the one
# `ExecStartPre=/bin/<shell> -c '...'` line in the unit matching PATTERN.
# systemd unescapes '$$' to a literal '$' before handing the line to the
# shell; mirror that here so the tests run exactly what the shell receives.
extract_exec_start_pre() {
    local line rest
    line=$(grep '^ExecStartPre=' "$unit" | grep -e "$1")
    [ -n "$line" ] || fail "no ExecStartPre in $unit matches '$1'"
    [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || fail "more than one ExecStartPre in $unit matches '$1'"

    rest=${line#ExecStartPre=}
    shell=${rest%% *}
    expr=${rest#"$shell" -c }
    case "$expr" in
        "'"*"'") expr=${expr#\'}; expr=${expr%\'} ;;
        *) fail "ExecStartPre matching '$1' is not a <shell> -c '...' command: $line" ;;
    esac
    expr=${expr//\$\$/\$}
}
