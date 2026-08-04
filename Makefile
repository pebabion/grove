.PHONY: help test build project app run xcode clean install icon

APP := build/Build/Products/Debug/Grove.app

help:
	@echo "make test     run GroveCore tests"
	@echo "make app      build Grove.app into ./build"
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
	xcodebuild -project Grove.xcodeproj -scheme Grove -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build \
		CODE_SIGNING_ALLOWED=NO build | tail -3

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
