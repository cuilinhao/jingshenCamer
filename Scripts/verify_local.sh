#!/bin/bash
# 仅做跨平台源码/规则检查，不等于 Apple SDK 编译或真实相机测试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"
command -v swiftc >/dev/null || { echo "需要 Swift 编译器" >&2; exit 1; }
command -v python3 >/dev/null || { echo "需要 Python 3" >&2; exit 1; }
echo "== Swift version =="
swiftc --version
echo "== Swift syntax only (NOT iOS typechecking) =="
swiftc -frontend -parse -swift-version 5 TestCamer/*.swift
swiftc -frontend -parse -swift-version 5 Tests/NativeRenderSmokeTests.swift
echo "== Compile and run pure Swift policy checks =="
swiftc TestCamer/DepthCapturePolicy.swift Tests/DepthPolicyTests.swift -o "$TMP/depth-policy-tests"
"$TMP/depth-policy-tests"
swiftc -O -swift-version 5 TestCamer/DepthCapturePolicy.swift TestCamer/DepthMath.swift Tests/DepthMathTests.swift -o "$TMP/depth-math-tests"
"$TMP/depth-math-tests"
echo "== Persistent TestLog checks =="
bash Scripts/verify_testlog.sh
echo "== Source contracts =="
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p 'test_*.py' -v
echo "== XML / assets =="
python3 - <<'PYXML'
from pathlib import Path
import json
import xml.etree.ElementTree as ET
root = Path('.')
files = list(root.glob('TestCamer/**/*.storyboard')) + list(root.glob('TestCamer.xcodeproj/**/*.xcscheme'))
files += list(root.glob('TestCamer.xcodeproj/**/*.xcworkspacedata'))
for p in files:
    ET.parse(p)
    print('XML OK:', p)
for p in root.glob('TestCamer/**/*.json'):
    json.loads(p.read_text())
    print('JSON OK:', p)
PYXML
if command -v plutil >/dev/null; then
  plutil -lint -- TestCamer/Info.plist TestCamer.xcodeproj/project.pbxproj
else
  echo "plutil 不可用：跳过 pbxproj 语法检查；没有把跳过标记为通过。"
fi
echo "Local checks complete. iOS SDK build / signing / device effects are NOT covered."
