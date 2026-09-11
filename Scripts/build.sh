#!/bin/zsh
set -euo pipefail
APP_ROOT="${0:A:h:h}"
APP_BUNDLE="$APP_ROOT/MacDuo.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target arm64-apple-macos14.0 \
  "$APP_ROOT"/Sources/*.swift \
  -o "$APP_BUNDLE/Contents/MacOS/MacDuo" \
  -framework AppKit -framework ScreenCaptureKit -framework Metal \
  -framework MetalKit -framework MetalPerformanceShaders -framework CoreVideo -framework IOKit -framework Carbon
cp "$APP_ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign - --identifier io.github.dakdevs.MacDuo "$APP_BUNDLE"
echo "$APP_BUNDLE"
