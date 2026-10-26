SHELL := /bin/bash
ROOT := $(shell pwd)

.PHONY: install dev build test dump clean

install:
	cd desktop && pnpm install

dev:
	cd desktop && pnpm tauri dev

build:
	cd desktop && pnpm tauri build

test:
	cd desktop && cargo test -p whalegirl-core
	cd desktop && pnpm build

dump:
	cd desktop && cargo run -p whalegirl-core --bin wg-dump -- --json

clean:
	rm -rf desktop/target desktop/dist
