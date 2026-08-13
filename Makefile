.PHONY: help test build project app debug-app run xcode clean install icon

# Release, because this is the build a person uses. Measured on the real library at a
# 1600x950 pane: a keystroke costs 2.6ms of drawing built with optimisation and 13.9ms
# without, and one frame is 16.7ms — so a debug build spends most of a frame on every
# character and stutters as soon as anything else wants the main thread. The DMG has always
# been Release; handing over debug builds is what made typing feel slow.
CONFIG ?= Release
APP := build/Build/Products/$(CONFIG)/Grove.app

help:
	@echo "make test     run GroveCore tests"
	@echo "make app      build Grove.app into ./build (Release)"
	@echo "make debug-app  the same, unoptimised, for a debugger or a crash log"
	@echo "make run      build and launch Grove.app"
	@echo "make xcode    regenerate the project and open Xcode"
	@echo "make install  copy Grove.app to /Applications"
	@echo "make icon     regenerate Grove.icns and icon.png"
	@echo "make clean    delete build output"

test:
	swift test

build:
	swift build

# Always regenerate: xcodegen globs the source directories, so a new file that
# project.yml never mentions still has to be picked up.
project:
	@xcodegen generate --quiet

# Builds into ./build rather than DerivedData so the app has a predictable path.
app: project
	xcodebuild -project Grove.xcodeproj -scheme Grove -configuration $(CONFIG) \
		-destination 'platform=macOS' -derivedDataPath build \
		CODE_SIGNING_ALLOWED=NO build | tail -3
	@$(MAKE) --no-print-directory sign

# macOS will not grant notification permission to a bundle whose only signature is
# the one the linker leaves on the executable. CODE_SIGNING_ALLOWED=NO above skips
# Xcode's signing, which needs a developer identity nobody should need to build
# this, so the bundle is signed ad-hoc here instead. That is also what seals the
# resources and gives the signature the bundle identifier rather than "Grove" —
# without it, requestAuthorization fails with UNErrorDomain error 1 and the feature
# looks broken in a way that has nothing to do with its code.
sign:
	@codesign --force --sign - $(APP)
	@codesign --verify --strict $(APP) && echo "signed $(APP)"

# For a debugger, or to read a crash log with useful frames.
debug-app:
	@$(MAKE) --no-print-directory app CONFIG=Debug

run: app
	open $(APP)

xcode: project
	open Grove.xcodeproj

install: app
	rm -rf /Applications/Grove.app
	cp -R $(APP) /Applications/Grove.app
	@echo "installed /Applications/Grove.app"

clean:
	rm -rf build .build Grove.xcodeproj

icon:
	swift scripts/make-icon.swift Grove/Resources icon.png
