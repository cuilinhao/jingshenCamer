#!/bin/bash
# Executes real Core Image filters against synthetic RGB and depth fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP / NOT VERIFIED: computational depth pixels require macOS + Xcode." >&2
  exit 2
fi
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-computational-depth.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
cd "$ROOT"
xcrun --sdk macosx swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/DepthBlurRenderer.swift TestCamer/ComputationalDepthRenderer.swift \
  Tests/ComputationalDepthRendererTests.swift -o "$TASK_TMP/computational-depth-tests"
"$TASK_TMP/computational-depth-tests"
