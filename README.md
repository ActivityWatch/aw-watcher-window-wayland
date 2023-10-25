aw-watcher-window-wayland
=========================

[![Build](https://github.com/ActivityWatch/aw-watcher-window-wayland/actions/workflows/build.yml/badge.svg)](https://github.com/ActivityWatch/aw-watcher-window-wayland/actions/workflows/build.yml)

Reports both window and afk status to the buckets aw-watcher-window and aw-watcher-afk respectively

**NOTE:** Does not support all wayland compositors, see "Compatibility" section below

### Dependencies

- pkg-config
- openssl-dev (debian libssl1.0-dev)

### How to build

1. Install rust and cargo (any recent stable version)
2. Run "cargo build --release"
3. A binary will be build inside the target/release folder named aw-watcher-window-wayland which can be run

### How to use

1. Start your wayland compositor
2. Start aw-server (or aw-qt, but you need to disable aw-watcher-afk and aw-watcher-window so they don't conflict)
3. Start aw-watcher-window-wayland

If you want to autostart aw-watcher-window-wayland without aw-qt, you can use the .desktop file provided in this git

### Compatibility

Only supports wayland window managers that implements the following wayland protocols:
- [idle.xml](https://wayland.app/protocols/kde-idle) (many)
- [wlr-foreign-toplevel-management-unstable-v1.xml](https://wayland.app/protocols/wlr-foreign-toplevel-management-unstable-v1) (very few)

| Window Manager | supported? | Details |
|-----|-----|-----|
| [phosh](https://gitlab.gnome.org/World/Phosh/phosh) | ✔️  | works |
| [sway](https://swaywm.org/) | ✔️  | works on version 1.5 and up |
| GNOME / [Mutter](https://gitlab.gnome.org/GNOME/mutter) | ❌ | no support for the protocols above |
| [Wayfire](https://wayfire.org/) | | not tested, but might work |
| KDE / [KWin](https://invent.kde.org/plasma/kwin) | ❌ |  |
