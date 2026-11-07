#!/usr/bin/env bash
# Regression test: the unit's wait for aw-server must work on a stock system
# and keep the journal quiet while it waits.
#
# The wait used to be `until nc -z localhost 5600`. nc is not installed by
# default on most distributions, and with it missing the loop never ends: the
# unit sits in "activating (start-pre)" forever even with aw-server running.
#
# Like wait_for_wayland_test.sh, this extracts the ExecStartPre from the
# shipped unit file. localhost:5600 is swapped for 127.0.0.1 and a port the
# test holds bound but not listening until it wants a listener, so neither an
# aw-server on this machine, another process grabbing the port, nor anything
# listening on ::1 can make the test pass or fail.

set -u
cd "$(dirname "$0")/.."
. tests/unit_lib.sh

tmpdir=$(mktemp -d)
listener_pid=
cleanup() {
    [ -z "$listener_pid" ] || kill "$listener_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$tmpdir"
}
trap cleanup EXIT

command -v python3 >/dev/null || { echo "SKIP: python3 not installed"; exit 77; }
command -v timeout >/dev/null || { echo "SKIP: timeout not installed"; exit 77; }

# Binds a free port and prints it, then listens two seconds after a line
# arrives on stdin. Until then a connect is refused.
coproc LISTENER { exec python3 -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1], flush=True)
sys.stdin.readline(); time.sleep(2); s.listen(8); time.sleep(120)'; }
listener_pid=$LISTENER_PID
read -r port <&"${LISTENER[0]}" || fail "could not reserve a port"

extract_exec_start_pre localhost/5600
expr=${expr//localhost\/5600/127.0.0.1\/$port}
ok "extracted aw-server wait expression from $unit"

# Shadow any real nc with one that behaves as if it were not installed.
mkdir -p "$tmpdir/bin"
printf '#!/bin/sh\necho "nc: command not found" >&2\nexit 127\n' > "$tmpdir/bin/nc"
chmod +x "$tmpdir/bin/nc"
export PATH="$tmpdir/bin:$PATH"

# The wait polls every 5s; see wait_for_wayland_test.sh for why BLOCK > 5.
run_wait() { timeout "$1" "$shell" -c "$expr" 2> "$tmpdir/stderr"; }
BLOCK=7
RETURN=15

# --- nothing listening -> must block, without spamming the journal --------
run_wait $BLOCK; [ $? -eq 124 ] || fail "wait returned with nothing listening on the port"
ok "blocks while aw-server is not listening"
[ ! -s "$tmpdir/stderr" ] || fail "wait wrote to stderr while polling: $(head -c 200 "$tmpdir/stderr")"
ok "polls silently"

# --- aw-server comes up later -> must return, without nc -------------------
echo >&"${LISTENER[1]}"
run_wait $RETURN || fail "wait did not return once aw-server was listening (does it depend on nc?)"
ok "returns once aw-server listens, with no nc installed"

echo "PASS"
