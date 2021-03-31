aw-watcher-window-wayland
=========================

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

### Compatibility

Only supports wayland window managers that implements the following wayland protocols:
- idle.xml (many)
- wlr-foreign-toplevel-management-unstable-v1.xml (very few)

Following window managers have implemented these protocols:
- phosh (works)
- sway (works on version 1.5 and up)
- Wayfire (Not tested, but might work)
