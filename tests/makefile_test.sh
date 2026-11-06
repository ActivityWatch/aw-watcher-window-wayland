#!/usr/bin/env bash
# Tests for the Makefile's build, install and service targets.
#
# The Makefile and unit file are copied into a scratch directory, and cargo
# and systemctl are replaced by stubs that log their arguments, so nothing
# here builds, installs into the real system or talks to a systemd manager.
#
# Covered:
# - a bare `make` builds instead of printing the help text;
# - the installed unit's ExecStart is the absolute path the binary was
#   installed to: systemd resolves a bare name only in its fixed search path
#   (/usr/local/bin:/usr/bin), so the default ~/.local install was never found;
# - `sudo make install` neither runs cargo as root nor pokes the system manager
#   about what is a user unit;
# - `sudo make enable-service` refuses instead of running `systemctl --user`
#   as root;
# - a DESTDIR install (packaging) stays inside DESTDIR, even without sudo, and
#   DESTDIR/PREFIX are taken from the environment as well as the command line;
# - the tests never see the real uid, so running them as root stays
#   sandboxed, and a root install without sudo targets /usr/local;
# - setup-wayland ignores a commented-out import line;
# - enable-service and setup-wayland get past `systemctl status`, which exits
#   3 while the unit is still waiting in start-pre.

set -u
cd "$(dirname "$0")/.."
. tests/unit_lib.sh


tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

src=$tmpdir/src
log=$tmpdir/calls.log
bin=aw-watcher-window-wayland

mkdir -p "$src" "$tmpdir/stubs"
cp Makefile "$unit" "$src/"
for cmd in cargo systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$cmd" "$log" > "$tmpdir/stubs/$cmd"
    chmod +x "$tmpdir/stubs/$cmd"
done
# Like the real thing for a unit sitting in "activating (start-pre)".
printf 'case "$*" in *" status "*) exit 3 ;; esac\n' >> "$tmpdir/stubs/systemctl"
# id -u reports $FAKE_UID (default: a normal user), so the Makefile never sees
# the real uid: run as root, it would otherwise install into /usr/local.
real_id=$(command -v id)
printf '#!/bin/sh\n[ "$*" = -u ] && { echo "${FAKE_UID:-1000}"; exit 0; }\nexec "%s" "$@"\n' "$real_id" > "$tmpdir/stubs/id"
chmod +x "$tmpdir/stubs/id"
export PATH="$tmpdir/stubs:$PATH"

fake_build() { mkdir -p "$src/target/release"; printf '#!/bin/sh\n' > "$src/target/release/$bin"; }
# run_make ENV... -- MAKE-ARGS...: run make in the sandbox with a fresh log and
# no inherited SUDO_USER/DESTDIR/PREFIX, so the developer's shell can't leak in.
run_make() {
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    : > "$log"
    env -u SUDO_USER -u DESTDIR -u PREFIX -u RELEASE HOME="$tmpdir/home" "${envs[@]}" \
        make --no-print-directory -C "$src" "$@" > "$tmpdir/out" 2>&1
}
exec_start() { sed -n 's/^ExecStart=//p' "$1"; }

# --- the shipped unit ------------------------------------------------------
case "$(exec_start "$unit")" in
    /*) ok "shipped unit has an absolute ExecStart" ;;
    *) fail "ExecStart in $unit is not an absolute path: $(exec_start "$unit")" ;;
esac

# --- default goal ----------------------------------------------------------
run_make -- -n || fail "bare make -n failed: $(cat "$tmpdir/out")"
grep -q '^cargo build' "$tmpdir/out" || fail "bare make does not build; it ran: $(head -3 "$tmpdir/out")"
ok "bare make builds"

# --- user install ----------------------------------------------------------
fake_build
run_make -- install || fail "make install failed: $(cat "$tmpdir/out")"
grep -q '^cargo build' "$log" || fail "make install did not build first"
installed=$tmpdir/home/.config/systemd/user/$unit
[ -f "$installed" ] || fail "make install did not install $installed"
want=$tmpdir/home/.local/bin/$bin
[ -x "$want" ] || fail "make install did not install $want"
[ "$(exec_start "$installed")" = "$want" ] || fail "installed ExecStart is '$(exec_start "$installed")', want '$want'"
ok "user install points ExecStart at ~/.local/bin"

run_make -- install PREFIX="$tmpdir/opt" || fail "make install PREFIX=... failed: $(cat "$tmpdir/out")"
[ "$(exec_start "$installed")" = "$tmpdir/opt/bin/$bin" ] || fail "with PREFIX set, installed ExecStart is '$(exec_start "$installed")'"
ok "ExecStart follows PREFIX"

# --- DESTDIR install without sudo (packaging, fakeroot) ------------------
dest=$tmpdir/dest
run_make DESTDIR="$dest" -- install || fail "DESTDIR=... make install failed: $(cat "$tmpdir/out")"
[ -f "$dest/usr/local/lib/systemd/user/$unit" ] || fail "DESTDIR install did not put the unit under DESTDIR"
[ -x "$dest/usr/local/bin/$bin" ] || fail "DESTDIR install did not put the binary under DESTDIR"
[ "$(exec_start "$dest/usr/local/lib/systemd/user/$unit")" = "/usr/local/bin/$bin" ] || fail "DESTDIR-installed ExecStart is '$(exec_start "$dest/usr/local/lib/systemd/user/$unit")'"
grep -q '^systemctl' "$log" && fail "DESTDIR install called systemctl: $(grep '^systemctl' "$log")"
ok "DESTDIR from the environment keeps the whole install inside DESTDIR"
rm -rf "$dest" "$tmpdir/home"

run_make PREFIX="$tmpdir/envopt" -- install || fail "PREFIX=... make install failed: $(cat "$tmpdir/out")"
installed=$tmpdir/home/.config/systemd/user/$unit
[ "$(exec_start "$installed")" = "$tmpdir/envopt/bin/$bin" ] || fail "PREFIX from the environment ignored; ExecStart is '$(exec_start "$installed")'"
ok "PREFIX is taken from the environment"

# --- root install (no sudo) -------------------------------------------------
# -n only: as root the install would write outside the sandbox.
run_make FAKE_UID=0 -- -n install || fail "make -n install as root failed: $(cat "$tmpdir/out")"
grep -q "/usr/local/bin/$bin" "$tmpdir/out" || fail "root install does not target /usr/local/bin: $(cat "$tmpdir/out")"
ok "root install targets /usr/local"

# --- sudo install ----------------------------------------------------------
dest=$tmpdir/dest
run_make SUDO_USER=nobody -- install DESTDIR="$dest" || fail "sudo make install failed: $(cat "$tmpdir/out")"
grep -q '^cargo' "$log" && fail "sudo make install ran cargo as root: $(grep '^cargo' "$log")"
ok "sudo make install does not build"
grep -q '^systemctl' "$log" && fail "sudo make install called systemctl: $(grep '^systemctl' "$log")"
ok "sudo make install leaves systemd managers alone"
installed=$dest/usr/local/lib/systemd/user/$unit
[ -f "$installed" ] || fail "sudo make install did not install $installed"
[ -x "$dest/usr/local/bin/$bin" ] || fail "sudo make install did not install the binary under DESTDIR"
[ "$(exec_start "$installed")" = "/usr/local/bin/$bin" ] || fail "sudo-installed ExecStart is '$(exec_start "$installed")', want /usr/local/bin/$bin (no DESTDIR)"
ok "sudo install points ExecStart at /usr/local/bin, without DESTDIR"

rm -rf "$src/target" "$dest"
run_make SUDO_USER=nobody -- install DESTDIR="$dest" && fail "sudo make install succeeded with nothing built"
grep -q '^cargo' "$log" && fail "sudo make install ran cargo as root when nothing was built"
grep -qi 'make install' "$tmpdir/out" || fail "sudo make install without a build gives no hint: $(cat "$tmpdir/out")"
ok "sudo make install without a build fails with a hint"

# --- enable-service under sudo ---------------------------------------------
run_make SUDO_USER=nobody -- enable-service && fail "sudo make enable-service succeeded"
grep -q '^systemctl' "$log" && fail "sudo make enable-service called systemctl as root: $(grep '^systemctl' "$log")"
ok "sudo make enable-service refuses"

# --- service targets as the user ------------------------------------------
run_make -- enable-service || fail "make enable-service failed with the unit in start-pre: $(tail -3 "$tmpdir/out")"
grep -q '^systemctl --user enable aw-watcher-window-wayland' "$log" || fail "enable-service did not enable the unit"
grep -q '^systemctl --user start --no-block' "$log" || fail "enable-service did not start the unit with --no-block"
ok "make enable-service succeeds while the unit waits in start-pre"

run_make -- disable-service || fail "make disable-service failed: $(tail -3 "$tmpdir/out")"
grep -q '^systemctl --user stop' "$log" && grep -q '^systemctl --user disable' "$log" || fail "disable-service did not stop and disable: $(cat "$log")"
ok "make disable-service stops and disables"

run_make SUDO_USER=nobody -- disable-service && fail "sudo make disable-service succeeded"
grep -q '^systemctl' "$log" && fail "sudo make disable-service called systemctl as root"
ok "sudo make disable-service refuses"

mkdir -p "$tmpdir/home/.config/sway"
echo "# sway config" > "$tmpdir/home/.config/sway/config"
run_make -- setup-wayland || fail "make setup-wayland failed: $(tail -3 "$tmpdir/out")"
[ "$(grep -c '^exec systemctl --user import-environment WAYLAND_DISPLAY$' "$tmpdir/home/.config/sway/config")" -eq 1 ] \
    || fail "setup-wayland did not add the import line to the sway config"
run_make -- setup-wayland || fail "second make setup-wayland failed: $(tail -3 "$tmpdir/out")"
[ "$(grep -c 'import-environment WAYLAND_DISPLAY' "$tmpdir/home/.config/sway/config")" -eq 1 ] \
    || fail "setup-wayland added the import line twice"
ok "make setup-wayland writes the sway import line once"

# A commented-out import line does not run, so it must not count.
printf '# exec systemctl --user import-environment WAYLAND_DISPLAY\n' > "$tmpdir/home/.config/sway/config"
run_make -- setup-wayland || fail "make setup-wayland failed: $(tail -3 "$tmpdir/out")"
[ "$(grep -c '^exec systemctl --user import-environment WAYLAND_DISPLAY$' "$tmpdir/home/.config/sway/config")" -eq 1 ] \
    || fail "setup-wayland took a commented-out sway import line for an active one"
ok "make setup-wayland ignores a commented-out sway import line"

rm -rf "$tmpdir/home/.config/sway"
mkdir -p "$tmpdir/home/.config/hypr"
printf '#exec-once = systemctl --user import-environment WAYLAND_DISPLAY\n' > "$tmpdir/home/.config/hypr/hyprland.conf"
run_make -- setup-wayland || fail "make setup-wayland failed: $(tail -3 "$tmpdir/out")"
[ "$(grep -c '^exec-once = systemctl --user import-environment WAYLAND_DISPLAY$' "$tmpdir/home/.config/hypr/hyprland.conf")" -eq 1 ] \
    || fail "setup-wayland took a commented-out Hyprland import line for an active one"
run_make -- setup-wayland || fail "second make setup-wayland failed: $(tail -3 "$tmpdir/out")"
[ "$(grep -c '^exec-once = systemctl' "$tmpdir/home/.config/hypr/hyprland.conf")" -eq 1 ] \
    || fail "setup-wayland added the Hyprland import line twice"
ok "make setup-wayland handles Hyprland, ignoring a commented-out line"

echo "PASS"
