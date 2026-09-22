#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHOTO_STORE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-photo-store-build.XXXXXX")"
trap 'rm -rf "$PHOTO_STORE_TMP"' EXIT
cd "$ROOT"
swiftc -O -swift-version 5 TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift \
  TestCamer/PhotoEditingModels.swift TestCamer/EditablePhotoStore.swift \
  Tests/PhotoEditingStoreTests.swift -o "$PHOTO_STORE_TMP/photo-store-tests"
"$PHOTO_STORE_TMP/photo-store-tests"
