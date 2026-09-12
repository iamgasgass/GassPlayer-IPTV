.PHONY: generate build archive ipa clean open verify

generate:
	xcodegen generate

open: generate
	open GassPlayer.xcodeproj

build: generate
	xcodebuild build \
		-project GassPlayer.xcodeproj -scheme GassPlayer \
		-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

archive: generate
	xcodebuild archive \
		-project GassPlayer.xcodeproj -scheme GassPlayer \
		-archivePath build/GassPlayer.xcarchive \
		-destination 'generic/platform=iOS' -sdk iphoneos \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
		AD_HOC_CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=""

ipa: archive
	mkdir -p build/Payload
	cp -r build/GassPlayer.xcarchive/Products/Applications/GassPlayer.app build/Payload/
	cd build && zip -r GassPlayer.ipa Payload && cd ..

verify:
	@find GassPlayer -name "*.swift" -exec basename {} \; | sort | uniq -d | \
		awk '{print "DUPLICATO: " $$0}'

clean:
	rm -rf build GassPlayer.xcodeproj DerivedData
