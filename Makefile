# Makefile for Ubuntu Zombie.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

VERSION := $(shell cat VERSION)

.PHONY: help lint test install-local verify package clean

help:
	@echo "Targets:"
	@echo "  lint           ShellCheck + bash -n + python compile"
	@echo "  test           non-root smoke and repository checks"
	@echo "  install-local  sudo ./scripts/setup-part-1.sh install (RUN ON A VM)"
	@echo "  verify         sudo ./scripts/setup-part-1.sh verify"
	@echo "  package        tar a release bundle into dist/"
	@echo "  clean          remove dist/ and python caches"

lint:
	@command -v shellcheck >/dev/null || { echo 'install shellcheck first' >&2; exit 1; }
	@set -e; \
	for f in $$(git ls-files | grep -E '\.(sh|bash)$$' || true) \
	         $$(git ls-files payload/bin); do \
	    head -n1 "$$f" | grep -q '^#!.*bash' || continue; \
	    echo "shellcheck $$f"; \
	    shellcheck --severity=warning "$$f"; \
	done
	bash tests/smoke.sh syntax
	bash tests/smoke.sh python

test:
	bash tests/smoke.sh all

install-local:
	@if [ "$$(id -u)" -ne 0 ]; then echo 'install-local must be run as root (sudo make install-local)'; exit 1; fi
	./scripts/setup-part-1.sh install

verify:
	@if [ -x /opt/ai-zombie/bin/verify ]; then /opt/ai-zombie/bin/verify; \
	 else ./scripts/setup-part-1.sh verify; fi

package:
	@mkdir -p dist
	@tar --exclude-vcs --exclude='dist' --exclude='__pycache__' \
	     -czf dist/ubuntu-zombie-$(VERSION).tar.gz \
	     scripts payload tests Makefile VERSION \
	     README.md CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md \
	     LICENSE .editorconfig \
	     SECURITY.md docs
	@echo "Wrote dist/ubuntu-zombie-$(VERSION).tar.gz"

clean:
	rm -rf dist
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
