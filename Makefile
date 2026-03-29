# lkf - Linux Kernel Framework
# Top-level Makefile for installing, testing, and building optional tools.

PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
DATADIR = $(PREFIX)/share/lkf

.PHONY: all install uninstall tools tools-kdress tools-unzboot check help

all: check

help:
	@echo "lkf Makefile targets:"
	@echo "  install        Install lkf to $(PREFIX)"
	@echo "  uninstall      Remove lkf from $(PREFIX)"
	@echo "  tools          Build all optional C tools (kdress, unzboot)"
	@echo "  tools-kdress   Clone and build elfmaster/kdress"
	@echo "  tools-unzboot  Clone and build eballetbo/unzboot"
	@echo "  check          Run self-tests"
	@echo "  clean          Remove build artifacts"

install:
	@echo "Installing lkf to $(PREFIX)..."
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(DATADIR)
	install -m 755 lkf.sh $(DESTDIR)$(BINDIR)/lkf
	cp -r core ci config profiles patches tools $(DESTDIR)$(DATADIR)/
	@echo "Installed. Run: lkf --help"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/lkf
	rm -rf $(DESTDIR)$(DATADIR)

tools: tools-kdress tools-unzboot
	@echo "Optional tools built."

tools-kdress:
	@echo "Building kdress..."
	@if [ ! -d /tmp/kdress-src ]; then \
		git clone --depth=1 https://github.com/elfmaster/kdress /tmp/kdress-src; \
	fi
	$(MAKE) -C /tmp/kdress-src
	cp /tmp/kdress-src/kdress tools/kdress/kdress
	@echo "kdress installed to tools/kdress/kdress"

tools-unzboot:
	@echo "Building unzboot..."
	@if [ ! -d /tmp/unzboot-src ]; then \
		git clone --depth=1 https://github.com/eballetbo/unzboot /tmp/unzboot-src; \
	fi
	cd /tmp/unzboot-src && meson setup build && meson compile -C build
	cp /tmp/unzboot-src/build/unzboot tools/unzboot/unzboot
	@echo "unzboot installed to tools/unzboot/unzboot"

check:
	@echo "Running lkf self-tests..."
	@bash tests/test_detect.sh
	@bash tests/test_config.sh
	@bash tests/test_integration.sh
	@echo "All tests passed."

lint:
	@echo "Running ShellCheck..."
	@command -v shellcheck >/dev/null 2>&1 || \
		{ echo "shellcheck not found — install it or run: make lint-install"; exit 1; }
	@find . -name '*.sh' | sort | xargs shellcheck --severity=warning --format=gcc
	@echo "ShellCheck passed."

lint-install:
	@echo "Installing ShellCheck..."
	@curl -fsSL https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz \
		| tar -xJ --strip-components=1 -C /usr/local/bin shellcheck-stable/shellcheck
	@echo "ShellCheck installed."

clean:
	rm -f tools/kdress/kdress tools/unzboot/unzboot
	rm -rf build/ downloads/
