# Contributing

This is an experimental macOS app. Please open an issue before a large change so the intended behavior and verification can be agreed on.

## Local checks

1. Install Xcode and run `scripts/install-xcodegen.sh` to get the pinned project generator.
2. Regenerate the project with the printed XcodeGen binary: `"$(scripts/install-xcodegen.sh | tail -1)" generate --spec project.yml`.
3. Run `xcrun swift-format lint --strict --recursive VoiceComputerPOC VoiceComputerPOCTests`.
4. Run `python3 scripts/check-swift-file-length.py` and `"$(scripts/install-quality-tool.sh swiftlint)" lint --strict --no-cache`.
5. Run `xcodebuild -quiet -project VoiceComputerPOC.xcodeproj -scheme VoiceComputerPOC -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData test CODE_SIGNING_ALLOWED=NO`.
6. Run `"$(scripts/install-quality-tool.sh periphery)" scan --project VoiceComputerPOC.xcodeproj --schemes VoiceComputerPOC --skip-build --index-store-path DerivedData/Index.noindex/DataStore --strict --disable-update-check`.

Pull requests must pass the macOS build and tests. Desktop behavior needs a short manual test note because CI does not have an interactive Computer Use session.

Swift source files are limited to 300 physical lines, and SwiftLint limits function bodies to 60 nonblank, noncomment lines. Keep tests and app code within the same limits. SwiftLint also checks cyclomatic complexity and force casts/tries. Periphery scans the Xcode index for unused declarations after the test build. Both tools are downloaded at pinned versions with SHA-256 verification by `scripts/install-quality-tool.sh`. If Periphery reports a declaration that is used dynamically, document the reason and use a narrowly scoped Periphery ignore comment.

Keep model access requests visible to the user. Do not broaden the Codex sandbox or grant persistent Computer Use access as part of a convenience change.
