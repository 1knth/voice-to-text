#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Apple tooling only. This package has no third-party dependencies or build plugins.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift build --scratch-path .build -c release
BIN_DIR="$(swift build --scratch-path .build -c release --show-bin-path)"
APP="$PWD/dist/Whisper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Whisper" "$APP/Contents/MacOS/Whisper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Keep this machine's reviewed configuration outside tracked source files.
INFERENCE_MANIFEST="${WHISPER_INFERENCE_MANIFEST:-$PWD/artifacts/ApprovedInference.local.json}"
if [[ ! -f "$INFERENCE_MANIFEST" ]]; then
    INFERENCE_MANIFEST="$PWD/Resources/ApprovedInference.json"
fi
cp "$INFERENCE_MANIFEST" "$APP/Contents/Resources/ApprovedInference.json"
/usr/bin/xcrun swiftc scripts/generate-icon.swift -o .build/generate-icon
.build/generate-icon "$PWD/.build/Whisper.iconset"
/usr/bin/iconutil -c icns .build/Whisper.iconset -o "$APP/Contents/Resources/Whisper.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
printf '\nBuilt local ad-hoc signed app: %s\n' "$APP"
printf 'Not notarized. Existing inference artifacts are hash-pinned for approved local testing.\n'
