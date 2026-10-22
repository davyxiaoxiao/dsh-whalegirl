SHELL := /bin/bash
ROOT := $(shell pwd)

.PHONY: build run snapshot preview art walk dist clean

build:
	./scripts/build_app.sh

run: build
	open build/WhaleGirl.app

snapshot: build
	./build/WhaleGirl.app/Contents/MacOS/WhaleGirl --snapshot "$(ROOT)/snapshots"

preview: snapshot
	python3 scripts/make_preview.py

art:
	python3 scripts/prepare_sheet.py dsh-image-gen/image-b35645c3.png --split 620,620

walk:
	python3 scripts/prepare_walk.py dsh-image-gen/image-bce7de69.png --splits 486,978

dist: build
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent build/WhaleGirl.app dist/鲸鱼娘.zip

clean:
	rm -rf build .build snapshots dist
