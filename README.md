aw-watcher-window-wayland
=========================

Work in Progress

Reports both window and afk status to the buckets aw-watcher-window-wayland and aw-watcher-afk-wayland respectively

Only supports wayland window managers that implements the following wayland protocols:
- idle.xml (most)
- wlr-foreign-toplevel-management-unstable-v1.xml (very few)

Following window managers are tested:
- phosh
- sway (with wlr-foreign-toplevel-management patch https://github.com/swaywm/sway/pull/4476)

