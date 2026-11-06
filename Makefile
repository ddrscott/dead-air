PREFIX ?= $(HOME)/.local
BIN = afm/afm
APP = build/DeadAir.app
APPBIN = $(APP)/Contents/MacOS/DeadAir

all: $(BIN) $(APPBIN)

# Top-level code with await needs main-file mode, so afm builds without -parse-as-library.
$(BIN): afm/afm.swift
	xcrun swiftc -O -target arm64-apple-macosx26.0 -o $@ $<

# The menu bar player: swiftc into a bundle made by hand, signed ad hoc.
app: $(APPBIN)

$(APPBIN): app/DeadAir.swift app/Info.plist app/AppIcon.icns
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp app/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx26.0 -o $@ app/DeadAir.swift
	codesign --force -s - $(APP)

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/afm
	ln -sf $(CURDIR)/bin/dead-air $(PREFIX)/bin/dead-air
	# The stages get a prefix: a bare `write` would shadow /usr/bin/write.
	for f in wire write speak; do ln -sf $(CURDIR)/bin/$$f $(PREFIX)/bin/dead-air-$$f; done

install-app: install $(APPBIN)
	rm -rf $(HOME)/Applications/DeadAir.app
	cp -R $(APP) $(HOME)/Applications/

# Developer ID signature, hardened runtime, notarized and stapled. See scripts/notarize.sh.
notarize:
	scripts/notarize.sh

install-notarized: install notarize
	rm -rf /Applications/DeadAir.app
	ditto $(APP) /Applications/DeadAir.app

# Redraws app/AppIcon.icns from tools/make-icon.swift.
icon:
	mkdir -p build/AppIcon.iconset
	xcrun swiftc -O tools/make-icon.swift -o build/make-icon
	build/make-icon build/icon-1024.png
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o app/AppIcon.icns

clean:
	rm -rf $(BIN) build

.PHONY: all app icon install install-app notarize install-notarized clean
