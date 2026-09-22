#!/bin/bash
# macOS + 完整 Xcode 下运行。不会修改工程签名，不会安装或启动 App。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "本脚本需要 macOS 和完整 Xcode；当前系统不支持 iOS SDK 构建。" >&2
  exit 2
fi
command -v xcodebuild >/dev/null || { echo "未找到 xcodebuild" >&2; exit 2; }
xcodebuild -version
bash "$ROOT/Scripts/verify_local.sh"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-xcodebuild.XXXXXX")"
echo "构建产物与日志目录：$BUILD_ROOT"
# 不签名的通用真机 SDK 构建，用来检查 iOS API、Swift 类型和资源编译。
xcodebuild -project "$ROOT/TestCamer.xcodeproj" -scheme TestCamer   -configuration Debug -destination 'generic/platform=iOS'   -derivedDataPath "$BUILD_ROOT/DerivedData" CODE_SIGNING_ALLOWED=NO build   2>&1 | tee "$BUILD_ROOT/build.log"
bash "$ROOT/Scripts/verify_render_on_mac.sh"
bash "$ROOT/Scripts/verify_apple_depth_on_mac.sh"
bash "$ROOT/Scripts/verify_photo_editing_store.sh"
bash "$ROOT/Scripts/verify_photo_editing_session.sh"
bash "$ROOT/Scripts/verify_photo_editing_render.sh"
bash "$ROOT/Scripts/verify_computational_depth.sh"
bash "$ROOT/Scripts/verify_monocular_depth.sh"
bash "$ROOT/Scripts/verify_computational_pipeline.sh"
bash "$ROOT/Scripts/verify_main_camera_rendering.sh"
echo "SDK 构建和合成图像渲染测试完成。请继续用 Xcode 签名运行到真机，按 Documentation/真机验收.md 验证。"
