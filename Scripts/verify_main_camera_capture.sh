#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-main-capture.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
swiftc -swift-version 5 "$ROOT/TestCamer/CameraLensPolicy.swift" \
  "$ROOT/TestCamer/MainCameraCapturePolicy.swift" "$ROOT/Tests/MainCameraCapturePolicyTests.swift" \
  -o "$OUTPUT/main-camera-policy-tests"
"$OUTPUT/main-camera-policy-tests"
