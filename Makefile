.PHONY: build generate test

SCHEME := Talrand

generate:
	nix shell nixpkgs\#xcodegen -c xcodegen generate

test:
	xcodebuild -project Talrand.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
		test -skipPackageUpdates -skipMacroValidation \
		OTHER_SWIFT_FLAGS='$$(inherited) -Xfrontend -disable-sandbox'

build:
	xcodebuild -project Talrand.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
		build -skipPackageUpdates -skipMacroValidation \
		OTHER_SWIFT_FLAGS='$$(inherited) -Xfrontend -disable-sandbox'
