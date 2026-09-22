#!/bin/bash
# 合成原生深度 HEIC 和普通 JPEG，验证导入、离线估计和保存重开；不访问用户相册。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "NOT VERIFIED: photo library import tests require macOS and Xcode." >&2
  exit 2
fi
BUILD_DIR="$(mktemp -d /tmp/testcamer-photo-import.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/TestLog.swift TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/NativeDepthSnapshot.swift TestCamer/CaptureModels.swift TestCamer/PhotoEditingModels.swift \
  TestCamer/AppleDepthRenderer.swift TestCamer/PortraitSubjectMask.swift TestCamer/DepthBlurRenderer.swift \
  TestCamer/DepthPhotoProcessor.swift TestCamer/PhotoEditingRenderer.swift TestCamer/EditablePhotoStore.swift \
  TestCamer/PhotoDepthData.swift TestCamer/MonocularDepthEstimator.swift TestCamer/ComputationalDepthRenderer.swift \
  TestCamer/PhotoLibraryImporter.swift Tests/AppleDepthRendererTests.swift Tests/PhotoLibraryImportTests.swift \
  -o "$BUILD_DIR/photo-library-import-tests"
xcrun coremlcompiler compile TestCamer/Models/DepthAnythingV2SmallF16.mlpackage "$BUILD_DIR"
"$BUILD_DIR/photo-library-import-tests" --model-smoke
