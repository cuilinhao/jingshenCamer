#!/bin/bash
# 输入必须为同一张照片，辅助 HEIC 需要包含系统原生深度；只在本地处理。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-replay.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/TestLog.swift TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/NativeDepthSnapshot.swift TestCamer/CaptureModels.swift \
  TestCamer/AppleDepthRenderer.swift TestCamer/PortraitSubjectMask.swift TestCamer/DepthBlurRenderer.swift TestCamer/DepthPhotoProcessor.swift \
  Tests/DepthPhotoReplay.swift -o "$TMP/replay"
"$TMP/replay" "$@"
