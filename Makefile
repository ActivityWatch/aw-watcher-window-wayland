.PHONY: all build test package

PREFIX=/usr/local/bin

CARGO_FLAGS=--release

all: build

build:
	cargo build $(CARGO_FLAGS)

test:
	./tests/compositor_crash_test.sh

install:
	install target/release/aw-watcher-window-wayland $(PREFIX)/aw-watcher-window-wayland
