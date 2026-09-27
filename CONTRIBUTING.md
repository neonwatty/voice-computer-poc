# Contributing

This is an experimental macOS app. Please open an issue before a large change so the intended behavior and verification can be agreed on.

## Local checks

1. Install Xcode and run `scripts/install-xcodegen.sh` to get the pinned project generator.
2. Regenerate the project with the printed XcodeGen binary: `"$(scripts/install-xcodegen.sh | tail -1)" generate --spec project.yml`.
3. Run `xcrun swift-format lint --strict --recursive VoiceComputerPOC VoiceComputerPOCTests`.
4. Run `xcodebuild -quiet -project VoiceComputerPOC.xcodeproj -scheme VoiceComputerPOC -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData test CODE_SIGNING_ALLOWED=NO`.

Pull requests must pass the macOS build and tests. Desktop behavior needs a short manual test note because CI does not have an interactive Computer Use session.

Keep model access requests visible to the user. Do not broaden the Codex sandbox or grant persistent Computer Use access as part of a convenience change.
