#!/bin/bash
# 本机合成 HEIC，实际执行苹果景深与 JPEG 编码；无需相机或相册权限。
set -euo pipefail
if [[ "${1:-}" == "--require-foreground-blur" && "$#" == "1" ]]; then
  export TESTCAMER_REQUIRE_FOREGROUND_BLUR=1
elif [[ "$#" != "0" ]]; then
  echo "Usage: bash Scripts/verify_photo_editing_render.sh [--require-foreground-blur]" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "NOT VERIFIED: photo editing render tests require macOS and Xcode." >&2
  exit 2
fi
BUILD_DIR="$(mktemp -d /tmp/testcamer-edit-render.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/TestLog.swift TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/PhotoDepthData.swift TestCamer/MonocularDepthEstimator.swift TestCamer/ComputationalDepthRenderer.swift \
  TestCamer/PhotoEditingModels.swift TestCamer/NativeDepthSnapshot.swift TestCamer/CaptureModels.swift \
  TestCamer/AppleDepthRenderer.swift TestCamer/PhotoEditingRenderer.swift \
  TestCamer/PortraitSubjectMask.swift TestCamer/DepthBlurRenderer.swift TestCamer/DepthPhotoProcessor.swift \
  Tests/AppleDepthRendererTests.swift Tests/PhotoEditingRenderTests.swift \
  -o "$BUILD_DIR/photo-editing-render-tests"
"$BUILD_DIR/photo-editing-render-tests"
