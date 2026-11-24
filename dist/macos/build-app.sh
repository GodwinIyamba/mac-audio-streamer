#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mac Audio Speaker"
BIN_NAME="MacAudioSpeaker"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_TMP="$ROOT_DIR/macos/.build-tmp"

rm -rf "$APP_BUNDLE" "$BUILD_TMP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/public" "$BUILD_TMP"

echo "1/4 Compiling native Swift macOS app..."
swiftc -O \
  -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreAudio \
  -framework CoreImage \
  -framework CryptoKit \
  -framework Network \
  -framework ServiceManagement \
  -framework Foundation \
  "$ROOT_DIR/macos/Sources/NetworkInfo.swift" \
  "$ROOT_DIR/macos/Sources/AudioSourceTracker.swift" \
  "$ROOT_DIR/macos/Sources/AudioTapEngine.swift" \
  "$ROOT_DIR/macos/Sources/LANAudioServer.swift" \
  "$ROOT_DIR/macos/Sources/AppController.swift" \
  "$ROOT_DIR/macos/Sources/MenuBarView.swift" \
  "$ROOT_DIR/macos/Sources/MacAudioSpeakerApp.swift" \
  -o "$MACOS_DIR/$BIN_NAME"

echo "2/4 Generating app icon..."
ICONSET_DIR="$BUILD_TMP/AppIcon.iconset"
swift "$ROOT_DIR/macos/generate-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

echo "3/4 Bundling Info.plist and web receiver assets..."
cp "$ROOT_DIR/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
cp -R "$ROOT_DIR/public/." "$RESOURCES_DIR/public/"

echo "4/4 Ad-hoc signing app bundle..."
codesign --force --deep --sign - --identifier "com.audiostreamer.MacAudioSpeaker" "$APP_BUNDLE" >/dev/null 2>&1

rm -rf "$BUILD_TMP"

echo ""
echo "Built: $APP_BUNDLE"
echo "Run:   open \"$APP_BUNDLE\""
echo "Tip:   Drag \"$APP_NAME.app\" to /Applications to keep permissions & Launch at Login stable."
