.PHONY: all build test install clean enable-service disable-service setup-wayland help not-sudo

.DEFAULT_GOAL := all

help:
	@echo "Available targets:"
	@echo "  all             - Build the project (default)"
	@echo "  build           - Build the project with cargo"
	@echo "  test            - Run the systemd unit and Makefile tests"
	@echo "  install         - Install binary and systemd service"
	@echo "  clean           - Remove build artifacts"
	@echo "  enable-service  - Enable and start the systemd service"
	@echo "  disable-service - Disable and stop the systemd service"
	@echo "  setup-wayland   - Configure Wayland environment import"

# A system install (sudo, root, or staging into DESTDIR for a package) puts the
# binary in $(PREFIX)/bin and the user unit in $(PREFIX)/lib/systemd/user, and
# leaves building and systemd to the user. Anything else is a per-user install
# into ~/.local and ~/.config/systemd/user. PREFIX is the installation root:
# the binary goes to $(PREFIX)/bin.
DESTDIR ?=
ifneq ($(SUDO_USER)$(DESTDIR),)
    SYSTEM_INSTALL := yes
else ifeq ($(shell id -u),0)
    SYSTEM_INSTALL := yes
endif
ifeq ($(SYSTEM_INSTALL),yes)
    PREFIX ?= /usr/local
else
    PREFIX ?= $(HOME)/.local
endif

# Build in release mode by default, unless RELEASE=false
ifeq ($(RELEASE), false)
	CARGO_FLAGS :=
	TARGET_DIR := debug
else
	CARGO_FLAGS := --release
	TARGET_DIR := release
endif

all: build

build:
	cargo build $(CARGO_FLAGS)

# A test exits 77 when its prerequisites are missing (python3). make
# aborts a recipe on any non-zero status, so map that back to success.
test:
	./tests/makefile_test.sh || [ $$? -eq 77 ]
	./tests/wait_for_server_test.sh || [ $$? -eq 77 ]
	./tests/wait_for_wayland_test.sh || [ $$? -eq 77 ]

BINARY := target/$(TARGET_DIR)/aw-watcher-window-wayland

# The unit's ExecStart is rewritten to wherever the binary is installed:
# systemd only resolves a bare command name in its own fixed search path
# (/usr/local/bin:/usr/bin), which does not include ~/.local/bin.
INSTALL_UNIT = sed 's|^ExecStart=.*|ExecStart=$(PREFIX)/bin/aw-watcher-window-wayland|' aw-watcher-window-wayland.service > $(1).tmp && \
	install -m 644 $(1).tmp $(1) && rm $(1).tmp

# A system install only installs what was built: under sudo, building here
# would run cargo as root and leave root-owned files in target/.
ifneq ($(SYSTEM_INSTALL),yes)
install: build
else
install:
	@[ -f $(BINARY) ] || { echo "$(BINARY) not found: run make as your user first, then sudo make install"; exit 1; }
endif
	# Install aw-watcher-window-wayland executable
	mkdir -p $(DESTDIR)$(PREFIX)/bin/
	install -m 755 $(BINARY) $(DESTDIR)$(PREFIX)/bin/aw-watcher-window-wayland
	# Install systemd user service
ifneq ($(SYSTEM_INSTALL),yes)
	mkdir -p $(HOME)/.config/systemd/user
	$(call INSTALL_UNIT,$(HOME)/.config/systemd/user/aw-watcher-window-wayland.service)
	systemctl --user daemon-reload || true
else
	mkdir -p $(DESTDIR)$(PREFIX)/lib/systemd/user
	$(call INSTALL_UNIT,$(DESTDIR)$(PREFIX)/lib/systemd/user/aw-watcher-window-wayland.service)
	@echo "Installed a user unit: run 'systemctl --user daemon-reload' as each user who wants it."
endif

clean:
	cargo clean

# The service targets manage the invoking user's own systemd manager, which
# root's `systemctl --user` cannot reach.
not-sudo:
ifneq ($(SUDO_USER),)
	@echo "This manages your user service: run it without sudo."; exit 1
endif

# --no-block on start/restart: the unit waits for aw-server and for a Wayland
# compositor, so a plain start blocks until both exist. That matters most for
# setup-wayland below, which depends on this target and exists to write the
# import-environment line the service is waiting for. Expect the status output
# to read "activating (start-pre)" when run before the compositor is up, and
# systemctl status to exit 3 then, which must not stop setup-wayland.
enable-service: not-sudo
	@echo "Enabling and starting service..."
	systemctl --user enable aw-watcher-window-wayland
	systemctl --user start --no-block aw-watcher-window-wayland
	@echo "Service status:"
	@systemctl --user status aw-watcher-window-wayland --no-pager || true

disable-service: not-sudo
	@echo "Disabling and stopping service..."
	systemctl --user stop aw-watcher-window-wayland
	systemctl --user disable aw-watcher-window-wayland
	@echo "Service disabled."

# Only an uncommented exec line counts as configured: a commented-out one
# never runs, and the service would wait for WAYLAND_DISPLAY forever.
setup-wayland: enable-service
	@echo "Configuring Wayland environment import..."
	@echo ""
	@echo "Detecting compositor configuration files..."
	@if [ -f ~/.config/sway/config ]; then \
		echo "Found Sway config at ~/.config/sway/config"; \
		if grep -Eq '^[[:space:]]*exec(_always)?[[:space:]]+systemctl --user import-environment[^#]*WAYLAND_DISPLAY' ~/.config/sway/config; then \
			echo "✓ Environment import already configured"; \
		else \
			echo "" >> ~/.config/sway/config; \
			echo "# Import WAYLAND_DISPLAY for systemd services" >> ~/.config/sway/config; \
			echo "exec systemctl --user import-environment WAYLAND_DISPLAY" >> ~/.config/sway/config; \
			echo "✓ Added environment import to Sway config"; \
			echo "  Please reload Sway config or log out and back in"; \
		fi; \
	elif [ -f ~/.config/hypr/hyprland.conf ]; then \
		echo "Found Hyprland config at ~/.config/hypr/hyprland.conf"; \
		if grep -Eq '^[[:space:]]*exec(-once)?[[:space:]]*=[[:space:]]*systemctl --user import-environment[^#]*WAYLAND_DISPLAY' ~/.config/hypr/hyprland.conf; then \
			echo "✓ Environment import already configured"; \
		else \
			echo "" >> ~/.config/hypr/hyprland.conf; \
			echo "# Import WAYLAND_DISPLAY for systemd services" >> ~/.config/hypr/hyprland.conf; \
			echo "exec-once = systemctl --user import-environment WAYLAND_DISPLAY" >> ~/.config/hypr/hyprland.conf; \
			echo "✓ Added environment import to Hyprland config"; \
			echo "  Please reload Hyprland config or log out and back in"; \
		fi; \
	else \
		echo "Could not detect compositor config file."; \
		echo ""; \
		echo "Please manually add this line to your compositor startup:"; \
		echo "  exec systemctl --user import-environment WAYLAND_DISPLAY"; \
		echo ""; \
		echo "Common locations:"; \
		echo "  - Sway: ~/.config/sway/config"; \
		echo "  - Hyprland: ~/.config/hypr/hyprland.conf"; \
		echo "  - Others: check your compositor documentation"; \
	fi
	@echo ""
	@echo "Restarting service to pick up environment changes..."
	@systemctl --user restart --no-block aw-watcher-window-wayland 2>/dev/null || echo "Note: Service restart will happen after compositor reload"
	@echo ""
	@echo "⚠ IMPORTANT: The environment variable will only be available after:"
	@echo "  1. Reloading your compositor config, OR"
	@echo "  2. Logging out and back in"
	@echo ""
	@echo "After that, verify the service is working:"
	@echo "  systemctl --user status aw-watcher-window-wayland"
