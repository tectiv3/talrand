.PHONY: build generate

SCHEME := Talrand

generate:
	nix shell nixpkgs\#xcodegen -c xcodegen generate

build:
	xcodebuild -project Talrand.xcodeproj -scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
		build -skipPackageUpdates -skipMacroValidation \
		OTHER_SWIFT_FLAGS='$$(inherited) -Xfrontend -disable-sandbox'
