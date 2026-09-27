#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all

echo "🔨 Building WhisperSub..."
swift build -c release

APP_DIR="$SCRIPT_DIR/WhisperSub.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/WhisperSub" "$MACOS_DIR/WhisperSub"
cp "Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/WhisperSub"

# Copy any SwiftPM resource bundles if generated
for bundle in .build/release/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$RESOURCES_DIR/"
    fi
done

codesign --force --deep --sign - --identifier "com.whispersub.mac" "$APP_DIR"

echo "✅ Packaged $APP_DIR"
