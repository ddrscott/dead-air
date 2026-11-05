PREFIX ?= $(HOME)/.local
BIN = afm/afm

all: $(BIN)

# -parse-as-library is off on purpose: top-level code with await needs main-file mode.
$(BIN): afm/afm.swift
	xcrun swiftc -O -target arm64-apple-macosx26.0 -o $@ $<

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/afm
	ln -sf $(CURDIR)/bin/dead-air $(PREFIX)/bin/dead-air
	# The stages get a prefix: a bare `write` would shadow /usr/bin/write.
	for f in wire write speak; do ln -sf $(CURDIR)/bin/$$f $(PREFIX)/bin/dead-air-$$f; done

clean:
	rm -f $(BIN)

.PHONY: all install clean
