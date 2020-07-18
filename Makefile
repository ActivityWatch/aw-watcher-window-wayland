.PHONY: all build package

PREFIX=/usr/local/bin

CARGO_FLAGS=--release

all: build

build:
	cargo build $(CARGO_FLAGS)

install:
	install target/release/aw-watcher-window-wayland $(PREFIX)/aw-watcher-window-wayland
