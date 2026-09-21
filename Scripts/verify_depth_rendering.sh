#!/bin/bash
# 使用本机 Core Image / HEIC 编解码调用真实生产渲染器，无需连接相机。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "景深像素回归需要 macOS 的 Core Image 和 AVFoundation。" >&2
  exit 2
fi
TEST_BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-depth-rendering.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_ROOT"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT/TestCamer/CaptureTypes.swift" \
  "$ROOT/TestCamer/DepthCapturePolicy.swift" \
  "$ROOT/TestCamer/DepthPhotoProcessor.swift" \
  "$ROOT/Tests/DepthRenderingTests.swift" \
  -o "$TEST_BUILD_ROOT/depth-rendering-tests"
"$TEST_BUILD_ROOT/depth-rendering-tests"
