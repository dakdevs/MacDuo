#!/bin/zsh
set -euo pipefail
APP_ROOT="${0:A:h:h}"
CHECK_ROOT="${1:-${TMPDIR:-/tmp}/MacDuo-verification}"
mkdir -p "$CHECK_ROOT"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-macos14.0 \
  "$APP_ROOT/Sources/PlaneProjection.swift" \
  "$APP_ROOT/Sources/PlaneRenderer.swift" \
  "$APP_ROOT/Tests/ProjectionChecks.swift" \
  -o "$CHECK_ROOT/projection-checks"
"$CHECK_ROOT/projection-checks" "$CHECK_ROOT" | tee "$CHECK_ROOT/results.txt"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-macos14.0 \
  "$APP_ROOT/Sources/LidMotion.swift" \
  "$APP_ROOT/Tests/LidMotionChecks.swift" \
  -o "$CHECK_ROOT/motion-checks"
"$CHECK_ROOT/motion-checks" | tee -a "$CHECK_ROOT/results.txt"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-macos14.0 \
  "$APP_ROOT/Sources/EffectTransition.swift" \
  "$APP_ROOT/Tests/EffectTransitionChecks.swift" \
  -o "$CHECK_ROOT/transition-checks"
"$CHECK_ROOT/transition-checks" | tee -a "$CHECK_ROOT/results.txt"
"$APP_ROOT/MacDuo.app/Contents/MacOS/MacDuo" --probe
codesign --verify --strict "$APP_ROOT/MacDuo.app"
plutil -lint "$APP_ROOT/MacDuo.app/Contents/Info.plist"
