#!/bin/bash
# Compile the bundled offline model and exercise real inference on macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "NOT VERIFIED: Core ML depth inference requires macOS and Xcode." >&2
  exit 2
fi
BUILD_DIR="$(mktemp -d /tmp/testcamer-monocular.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$ROOT"
(cd TestCamer/Models && shasum -a 256 -c DepthAnythingV2-SHA256SUMS.txt)
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/MonocularDepthEstimator.swift Tests/MonocularDepthEstimatorTests.swift \
  -o "$BUILD_DIR/monocular-depth-tests"
"$BUILD_DIR/monocular-depth-tests" --expect-missing-model
xcrun coremlcompiler compile TestCamer/Models/DepthAnythingV2SmallF16.mlpackage "$BUILD_DIR"
"$BUILD_DIR/monocular-depth-tests" --smoke
