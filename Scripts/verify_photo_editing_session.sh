#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-edit-session.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$ROOT"
swiftc -swift-version 5 TestCamer/DepthMath.swift TestCamer/DepthCapturePolicy.swift TestCamer/PhotoEditingModels.swift TestCamer/PhotoEditingSession.swift Tests/PhotoEditingSessionTests.swift -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
