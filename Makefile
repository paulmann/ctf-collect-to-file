# Makefile for ctf — Collect To File
#
#   make install [PREFIX=/usr/local]   install into $(PREFIX)/bin
#   make uninstall                     remove installed files
#   make test                          run the full test suite
#   make lint                          shellcheck (severity=style)
#   make check                         lint + test
#   make version                       print the version from VERSION
#   make dist                          build a release tarball in dist/

SHELL      := /bin/bash
PREFIX     ?= $(HOME)/.local
BINDIR     ?= $(PREFIX)/bin
VERSION    := $(shell cat VERSION 2>/dev/null | tr -d ' \t\r\n')
SHELLCHECK ?= shellcheck
DISTDIR    := dist
NAME       := ctf-collect-to-file

SH_FILES   := ctf.sh install.sh tests/lib.sh tests/run_tests.sh \
              $(wildcard tests/test_*.sh)

.PHONY: all help install uninstall test lint check version dist clean

all: help

help:
	@echo "ctf $(VERSION) — targets:"
	@echo "  make install [PREFIX=/usr/local]  install into \$$(PREFIX)/bin"
	@echo "  make uninstall                    remove installed files"
	@echo "  make test                         run the test suite"
	@echo "  make lint                         shellcheck --severity=style"
	@echo "  make check                        lint + test"
	@echo "  make version                      print the version"
	@echo "  make dist                         build dist/$(NAME)-$(VERSION).tar.gz"
	@echo "  make clean                        remove build artefacts"

install:
	@./install.sh --prefix "$(PREFIX)"

uninstall:
	@./install.sh --prefix "$(PREFIX)" --uninstall

test:
	@bash tests/run_tests.sh

lint:
	@command -v $(SHELLCHECK) >/dev/null 2>&1 || { \
	  echo "shellcheck not found — install it or set SHELLCHECK=/path/to/shellcheck"; exit 2; }
	@$(SHELLCHECK) --severity=style $(SH_FILES)
	@echo "shellcheck: clean"

check: lint test

version:
	@echo "$(VERSION)"

dist:
	@mkdir -p $(DISTDIR)
	@rm -rf $(DISTDIR)/$(NAME)-$(VERSION)
	@mkdir -p $(DISTDIR)/$(NAME)-$(VERSION)
	@cp -a ctf.sh ctf.ps1 ctf.bat VERSION README.md CHANGELOG.md LICENSE \
	       Makefile install.sh .gitattributes .gitignore .editorconfig \
	       tests docs $(DISTDIR)/$(NAME)-$(VERSION)/ 2>/dev/null || true
	@tar -czf $(DISTDIR)/$(NAME)-$(VERSION).tar.gz -C $(DISTDIR) $(NAME)-$(VERSION)
	@sha256sum $(DISTDIR)/$(NAME)-$(VERSION).tar.gz | tee $(DISTDIR)/$(NAME)-$(VERSION).tar.gz.sha256
	@echo "built $(DISTDIR)/$(NAME)-$(VERSION).tar.gz"

clean:
	@rm -rf $(DISTDIR)
	@find . -name '*.bak-*' -delete 2>/dev/null || true
	@echo "cleaned"
