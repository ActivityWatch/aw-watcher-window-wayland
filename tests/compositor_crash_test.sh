#!/usr/bin/env bash
# Regression test: when the Wayland compositor dies, the watcher must exit so
# that systemd (Restart=always) can restart it against the new compositor.
#
# Background: wayland-client 0.24 busy-loops on EPIPE inside dispatch() when
# the compositor connection dies (the flush retry loop in rust_imp/queues.rs
# never breaks on EPIPE). Without a hangup check the watcher then hangs
# forever, burning CPU and recording nothing, while systemd still considers
# the service healthy.
#
# Requires: sway (started headless), aw-server (rust), nc, cargo.

set -u
cd "$(dirname "$0")/.."

tmpdir=$(mktemp -d)
watcher_pid=
sway_pid=
server_pid=

cleanup() {
    [ -n "$watcher_pid" ] && kill "$watcher_pid" 2>/dev/null
    [ -n "$sway_pid" ] && kill "$sway_pid" 2>/dev/null
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$tmpdir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v sway >/dev/null || { echo "SKIP: sway not installed"; exit 77; }
command -v aw-server >/dev/null || { echo "SKIP: aw-server not installed"; exit 77; }
command -v nc >/dev/null || { echo "SKIP: nc not installed"; exit 77; }

# Use the release build: the debug build aborts at startup on modern rustc
# (null-pointer check in the ancient nix 0.15 dependency that release mode
# doesn't perform), and release is what actually ships anyway.
echo "# Building watcher (release; run with --testing => port 5666)"
cargo build --release --quiet 2>"$tmpdir/build.log" \
    || { cat "$tmpdir/build.log" >&2; fail "cargo build failed"; }

# The watcher in testing mode talks to port 5666; start an isolated aw-server
# there unless one is already listening.
if ! nc -z localhost 5666 2>/dev/null; then
    aw-server --testing --port 5666 --dbpath "$tmpdir/aw-test.db" --no-legacy-import \
        >"$tmpdir/aw-server.log" 2>&1 &
    server_pid=$!
fi
for _ in $(seq 50); do nc -z localhost 5666 2>/dev/null && break; sleep 0.2; done
nc -z localhost 5666 2>/dev/null || fail "aw-server did not start listening on port 5666"

# Start a headless sway; it picks its own socket name, so have it report
# WAYLAND_DISPLAY back to us via its config.
cat > "$tmpdir/report-display.sh" <<EOF
#!/bin/sh
printf %s "\$WAYLAND_DISPLAY" > "$tmpdir/display"
EOF
chmod +x "$tmpdir/report-display.sh"
echo "exec $tmpdir/report-display.sh" > "$tmpdir/sway.cfg"

env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK \
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$tmpdir/sway.cfg" >"$tmpdir/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 50); do [ -s "$tmpdir/display" ] && break; sleep 0.2; done
[ -s "$tmpdir/display" ] || { cat "$tmpdir/sway.log" >&2; fail "headless sway did not start"; }
display=$(cat "$tmpdir/display")
echo "# headless sway is up on $display (pid $sway_pid)"

env WAYLAND_DISPLAY="$display" ./target/release/aw-watcher-window-wayland --testing \
    >"$tmpdir/watcher.log" 2>&1 &
watcher_pid=$!
for _ in $(seq 50); do
    grep -q "Watcher is now running" "$tmpdir/watcher.log" 2>/dev/null && break
    sleep 0.2
done
grep -q "Watcher is now running" "$tmpdir/watcher.log" \
    || { cat "$tmpdir/watcher.log" >&2; fail "watcher did not start"; }
echo "# watcher is running (pid $watcher_pid)"

echo "# killing sway to simulate a compositor crash"
kill -9 "$sway_pid" 2>/dev/null
wait "$sway_pid" 2>/dev/null
sway_pid=

# The watcher must exit within a few seconds so systemd can restart it.
# (kill -0 succeeds on a zombie child, so check the process state instead.)
for _ in $(seq 20); do
    state=$(ps -o stat= -p "$watcher_pid" 2>/dev/null)
    if [ -z "$state" ] || [ "${state:0:1}" = "Z" ]; then
        wait "$watcher_pid" 2>/dev/null
        rc=$?
        watcher_pid=
        echo "# watcher exited with code $rc"
        echo "PASS: watcher exited after compositor death"
        exit 0
    fi
    sleep 0.5
done

echo "--- watcher log ---" >&2
cat "$tmpdir/watcher.log" >&2
fail "watcher still running 10s after compositor death (would hang forever, recording nothing)"
