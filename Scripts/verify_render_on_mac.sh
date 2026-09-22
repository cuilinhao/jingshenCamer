#!/bin/bash
# 真正运行 Core Image 渲染测试（合成图像/深度），不启动相机，不需要相册权限。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP / NOT VERIFIED: native rendering tests require macOS + Xcode, not Linux." >&2
  exit 2
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-native.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/TestLog.swift TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/NativeDepthSnapshot.swift TestCamer/CaptureModels.swift TestCamer/PhotoEditingModels.swift \
  TestCamer/AppleDepthRenderer.swift TestCamer/PortraitSubjectMask.swift TestCamer/DepthBlurRenderer.swift TestCamer/DepthPhotoProcessor.swift \
  Tests/AppleDepthRendererTests.swift Tests/NativeRenderSmokeTests.swift -o "$TMP/native-render-tests"
"$TMP/native-render-tests"
