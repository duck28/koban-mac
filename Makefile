# Koban for macOS — run on a Mac with Xcode 16+ and XcodeGen (brew install xcodegen).

.PHONY: project open build app app-debug install test clean

project:            ## Generate Koban.xcodeproj from project.yml
	xcodegen generate

open: project       ## Generate and open in Xcode
	open Koban.xcodeproj

build: project      ## Debug build of Koban.app (unsigned)
	xcodebuild -project Koban.xcodeproj -scheme Koban -configuration Debug \
		-derivedDataPath build CODE_SIGNING_ALLOWED=NO build

app:                ## Release Koban.app via swiftc (no Xcode needed) -> build/app
	scripts/build-app.sh

app-debug:          ## Debug Koban.app via swiftc
	scripts/build-app.sh --debug

install: app        ## Copy build/app/Koban.app to /Applications
	ditto build/app/Koban.app /Applications/Koban.app

test:               ## Unit tests for the core (models, calculations, vault crypto)
	cd KobanKit && swift test

clean:
	rm -rf build KobanKit/.build Koban.xcodeproj
