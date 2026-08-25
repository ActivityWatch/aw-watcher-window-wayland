#!/usr/bin/env bash
# Regression test: the systemd unit must not start the watcher before the
# Wayland compositor is actually usable.
#
# Background: the service is WantedBy=default.target, so on a machine where
# the compositor is started manually it is launched at login, minutes before
# any compositor exists. get_wl_display() then panics (exit 101) and the unit
# burns through StartLimitBurst long before the compositor shows up, leaving
# the watcher dead for the rest of the session.
#
# Waiting for the socket alone is not enough: a compositor creates its socket
# and only then runs `systemctl --user import-environment WAYLAND_DISPLAY`.
# Starting in that window means connect_to_env() still fails. The gate must
# therefore require BOTH the imported WAYLAND_DISPLAY and its socket -- which
# is what case C below pins down, since it is the only case that tells the
# shipped gate apart from one that merely waits for a socket to appear.
#
# This test extracts the ExecStartPre wait expression from the shipped unit
# file and exercises it against a faked systemd user environment, so it tests
# what actually ships rather than a copy of it. Note that it cannot catch a
# missing '$$' escape: systemd leaves a bare '$wd' inside a quoted word alone,
# so escaped and unescaped forms reach /bin/sh identically.

set -u
cd "$(dirname "$0")/.."

unit=aw-watcher-window-wayland.service
tmpdir=$(mktemp -d)
sock_pids="$tmpdir/sock.pids"
: > "$sock_pids"

kill_sockets() {
    while read -r p; do kill "$p" 2>/dev/null; done < "$sock_pids"
    : > "$sock_pids"
}
cleanup() {
    kill_sockets
    wait 2>/dev/null
    rm -rf "$tmpdir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# 77 is the automake "skip" convention, but make(1) aborts the whole recipe on
# any non-zero status, so the Makefile maps it back to 0.
command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 77; }
command -v timeout >/dev/null || { echo "SKIP: timeout not installed"; exit 77; }

# --- extract the wait expression from the unit -----------------------------
# systemd unescapes '$$' to a literal '$' before handing the line to /bin/sh;
# mirror that here so we run exactly what sh will receive.
line=$(grep '^ExecStartPre=' "$unit" | grep WAYLAND_DISPLAY)
[ -n "$line" ] || fail "no ExecStartPre in $unit waits for WAYLAND_DISPLAY"

expr=${line#ExecStartPre=/bin/sh -c }
case "$expr" in
    "'"*"'") expr=${expr#\'}; expr=${expr%\'} ;;
    *) fail "WAYLAND_DISPLAY ExecStartPre is not a /bin/sh -c '...' command: $line" ;;
esac
expr=${expr//\$\$/\$}
ok "extracted wait expression from $unit"

# --- fake systemd user environment -----------------------------------------
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/systemctl" <<'EOF'
#!/bin/sh
# The gate must ask the *user* manager for its environment. Anything else --
# the system manager, or a different subcommand -- is a regression, so refuse
# loudly instead of quietly serving the fixture.
if [ "$1" != "--user" ] || [ "$2" != "show-environment" ]; then
    echo "fake systemctl: unexpected invocation: $*" >&2
    exit 64
fi
cat "$FAKE_ENV"
EOF
chmod +x "$tmpdir/bin/systemctl"

export PATH="$tmpdir/bin:$PATH"
export XDG_RUNTIME_DIR="$tmpdir/run"
export FAKE_ENV="$tmpdir/env"
mkdir -p "$XDG_RUNTIME_DIR"

set_env() { printf 'LANG=C\n' > "$FAKE_ENV"; [ $# -eq 0 ] || printf 'WAYLAND_DISPLAY=%s\n' "$1" >> "$FAKE_ENV"; }

make_socket() {
    python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(120)' "$1" &
    # Record the pid in a file rather than a variable: make_socket is also
    # called from a subshell, whose variables never reach the EXIT trap.
    echo $! >> "$sock_pids"
    for _ in $(seq 50); do [ -S "$1" ] && return; sleep 0.1; done
    fail "could not create test socket $1"
}

# The gate polls every 5s, so a "must block" timeout has to exceed that or it
# only proves the predicate was false once, not that the loop keeps polling.
run_wait() { timeout "$1" /bin/sh -c "$expr"; }
BLOCK=7
RETURN=25

# --- case A: no compositor, nothing imported -> must block -----------------
set_env
run_wait $BLOCK; [ $? -eq 124 ] || fail "wait returned with no WAYLAND_DISPLAY imported and no socket"
ok "blocks when neither WAYLAND_DISPLAY nor a socket is present"

# --- case B: imported, but socket not there yet -> must block --------------
set_env wayland-9
run_wait $BLOCK; [ $? -eq 124 ] || fail "wait returned while the socket was missing"
ok "blocks when WAYLAND_DISPLAY is set but the socket is missing"

# --- case C: socket present, but not imported yet -> must block ------------
# The discriminating case. A gate that merely waits for a socket to appear
# passes every other case in this file and fails only this one.
make_socket "$XDG_RUNTIME_DIR/wayland-9"
set_env
run_wait $BLOCK; [ $? -eq 124 ] || fail "wait returned on a socket alone, before WAYLAND_DISPLAY was imported"
ok "blocks when the socket exists but WAYLAND_DISPLAY is not imported"

# --- case D: both present -> must return promptly --------------------------
set_env wayland-9
run_wait $RETURN || fail "wait did not return once display and socket were both present"
ok "returns once WAYLAND_DISPLAY and its socket are both present"

# --- case E: appears late (the real boot ordering) -------------------------
kill_sockets
rm -f "$XDG_RUNTIME_DIR/wayland-9"
set_env
(
    sleep 2
    make_socket "$XDG_RUNTIME_DIR/wayland-9"
    set_env wayland-9
    sleep 60
) &
late_pid=$!
run_wait $RETURN || { kill $late_pid 2>/dev/null; fail "wait did not pick up a compositor that started later"; }
kill $late_pid 2>/dev/null
ok "returns when the compositor starts after the unit"

echo "PASS"
