.PHONY: build run kiosk app install clean

build:
	swift build

run: build
	.build/debug/AOLOS --windowed

kiosk: build
	.build/debug/AOLOS

app:
	./scripts/bundle.sh

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: app
	rm -rf /Applications/AOL-OS.app
	cp -R build/AOL-OS.app /Applications/AOL-OS.app
	-$(LSREGISTER) -u build/AOL-OS.app 2>/dev/null
	$(LSREGISTER) -f /Applications/AOL-OS.app

clean:
	rm -rf .build build
