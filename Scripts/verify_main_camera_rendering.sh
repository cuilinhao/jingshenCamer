#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/testcamer-main-render.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/TestLog.swift TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/NativeDepthSnapshot.swift TestCamer/CaptureModels.swift TestCamer/PhotoEditingModels.swift \
  TestCamer/AppleDepthRenderer.swift TestCamer/PortraitSubjectMask.swift TestCamer/DepthBlurRenderer.swift \
  TestCamer/DepthPhotoProcessor.swift TestCamer/PhotoEditingRenderer.swift \
  TestCamer/PhotoDepthData.swift TestCamer/MonocularDepthEstimator.swift TestCamer/ComputationalDepthRenderer.swift \
  Tests/AppleDepthRendererTests.swift Tests/MainCameraRenderingTests.swift -o "$BUILD_DIR/main-render-tests"
"$BUILD_DIR/main-render-tests"
