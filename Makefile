# Local-only release for SIPDesk (no cloud CI). Details: ~/.agents/skills/jeishod-release/SKILL.md
#   make test | make build | make release [DRY_RUN=1]
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

VERSION  ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUILD    ?=
APP      := build/SIPDesk.app
DMG      := build/distribution/SIPDesk-$(VERSION)-AppleSilicon.dmg
NOTES    := docs/releases/v$(VERSION).md
RELEASE  ?= jeishod-release
DRY_RUN  ?=
DRY      := $(if $(DRY_RUN),--dry-run,)

.PHONY: test build release

test:
	./Scripts/test.sh

# Ad-hoc signed app; the Developer ID signature is applied by `make release`.
build:
	./build.sh

release:
ifeq ($(DRY_RUN),)
	$(MAKE) test
	$(MAKE) build
else
	@echo "[dry-run] skipped: make test, make build"
endif
	$(RELEASE) $(DRY) mac-sign $(APP) --entitlements Resources/SIPDesk.entitlements
	$(RELEASE) $(DRY) mac-notarize $(APP)
ifeq ($(DRY_RUN),)
	/usr/bin/python3 Scripts/package-dmg.py
else
	@echo "[dry-run] skipped: /usr/bin/python3 Scripts/package-dmg.py (DMG with sources, sign, notarize)"
endif
	$(RELEASE) $(DRY) gh-release v$(VERSION) $(if $(wildcard $(NOTES)),--notes $(NOTES),) --asset $(DMG) --asset $(DMG).sha256
