.PHONY: all build test install clean enable-service disable-service setup-wayland help

help:
	@echo "Available targets:"
	@echo "  all             - Build the project (default)"
	@echo "  build           - Build the project with cargo"
	@echo "  test            - Run the systemd unit tests"
	@echo "  install         - Install binary and systemd service"
	@echo "  clean           - Remove build artifacts"
	@echo "  enable-service  - Enable and start the systemd service"
	@echo "  disable-service - Disable and stop the systemd service"
	@echo "  setup-wayland   - Configure Wayland environment import"

# Determine PREFIX based on whether we're using sudo or not
DESTDIR :=
ifeq ($(SUDO_USER),)
    PREFIX := $(HOME)/.local
else
    PREFIX := /usr/local
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

# A test exits 77 when its prerequisites are missing (here: python3). make
# aborts a recipe on any non-zero status, so map that back to success.
test:
	./tests/wait_for_wayland_test.sh || [ $$? -eq 77 ]

install: build
	# Install aw-watcher-window-wayland executable
	mkdir -p $(DESTDIR)$(PREFIX)/bin/
	install -m 755 target/$(TARGET_DIR)/aw-watcher-window-wayland $(DESTDIR)$(PREFIX)/bin/aw-watcher-window-wayland
	# Install systemd user service
ifeq ($(SUDO_USER),)
	mkdir -p $(HOME)/.config/systemd/user
	install -m 644 aw-watcher-window-wayland.service $(HOME)/.config/systemd/user/aw-watcher-window-wayland.service
	systemctl --user daemon-reload || true
else
	mkdir -p $(DESTDIR)$(PREFIX)/lib/systemd/user
	install -m 644 aw-watcher-window-wayland.service $(DESTDIR)$(PREFIX)/lib/systemd/user/aw-watcher-window-wayland.service
	systemctl daemon-reload || true
endif

clean:
	cargo clean

# --no-block on start/restart: the unit waits for aw-server and for a Wayland
# compositor, so a plain start blocks until both exist. That matters most for
# setup-wayland below, which depends on this target and exists to write the
# import-environment line the service is waiting for. Expect the status output
# to read "activating (start-pre)" when run before the compositor is up.
enable-service:
	@echo "Enabling and starting service..."
ifeq ($(SUDO_USER),)
	systemctl --user enable aw-watcher-window-wayland
	systemctl --user start --no-block aw-watcher-window-wayland
	@echo "Service status:"
	@systemctl --user status aw-watcher-window-wayland --no-pager
else
	@echo "Note: For user service, run without sudo"
	systemctl --user enable aw-watcher-window-wayland
	systemctl --user start --no-block aw-watcher-window-wayland
endif

disable-service:
	@echo "Disabling and stopping service..."
	systemctl --user stop aw-watcher-window-wayland
	systemctl --user disable aw-watcher-window-wayland
	@echo "Service disabled."

setup-wayland: enable-service
	@echo "Configuring Wayland environment import..."
	@echo ""
	@echo "Detecting compositor configuration files..."
	@if [ -f ~/.config/sway/config ]; then \
		echo "Found Sway config at ~/.config/sway/config"; \
		if grep -q "systemctl --user import-environment WAYLAND_DISPLAY" ~/.config/sway/config; then \
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
		if grep -q "systemctl --user import-environment WAYLAND_DISPLAY" ~/.config/hypr/hyprland.conf; then \
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
