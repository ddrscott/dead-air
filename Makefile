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

$(APPBIN): app/DeadAir.swift app/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp app/Info.plist $(APP)/Contents/Info.plist
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

clean:
	rm -rf $(BIN) build

.PHONY: all app install install-app clean
