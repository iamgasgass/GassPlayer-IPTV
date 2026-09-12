.PHONY: generate build clean open

generate:
	xcodegen generate

open: generate
	open GassPlayer.xcodeproj

build: generate
	xcodebuild build \
		-project GassPlayer.xcodeproj \
		-scheme GassPlayer \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO

archive: generate
	xcodebuild archive \
		-project GassPlayer.xcodeproj \
		-scheme GassPlayer \
		-archivePath build/GassPlayer.xcarchive \
		-destination 'generic/platform=iOS' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY=""

ipa: archive
	mkdir -p build/Payload
	cp -r build/GassPlayer.xcarchive/Products/Applications/GassPlayer.app build/Payload/
	cd build && zip -r GassPlayer-unsigned.ipa Payload && cd ..

clean:
	rm -rf build GassPlayer.xcodeproj DerivedData
