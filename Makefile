.PHONY: build generate

SCHEME := MTGBlue

generate:
	nix shell nixpkgs\#xcodegen -c xcodegen generate

build: generate
	xcodebuild -project MTGBlue.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
		build -skipPackageUpdates -skipMacroValidation \
		OTHER_SWIFT_FLAGS='$$(inherited) -Xfrontend -disable-sandbox'
