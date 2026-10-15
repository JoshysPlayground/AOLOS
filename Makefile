.PHONY: build run kiosk app clean

build:
	swift build

run: build
	.build/debug/AOLOS --windowed

kiosk: build
	.build/debug/AOLOS

app:
	./scripts/bundle.sh

clean:
	rm -rf .build build
