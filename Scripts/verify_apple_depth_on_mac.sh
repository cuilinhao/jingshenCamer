#!/bin/bash
# In-memory synthetic HEIC + real Core Image execution; no camera or photo library.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "NOT VERIFIED: Apple depth rendering requires macOS and Xcode." >&2
  exit 2
fi
BUILD_DIR="$(mktemp -d /tmp/testcamer-apple-depth.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -D APPLE_DEPTH_TEST_MAIN TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/AppleDepthRenderer.swift Tests/AppleDepthRendererTests.swift \
  -o "$BUILD_DIR/apple-depth-tests"
"$BUILD_DIR/apple-depth-tests"
