import Foundation

@main
struct MainCameraCapturePolicyTests {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { failures += 1; print("FAIL: \(message)") }
        }
        let wide = CameraLensOption(id: "wide-A", kind: .wide)
        let rgb = [CameraLensCandidate(id: "ultra", kind: .ultraWide, isVirtual: false),
                   CameraLensCandidate(id: "wide-A", kind: .wide, isVirtual: false)]
        func candidate(_ id: String, _ kind: MainCameraAuxiliaryKind, locked: Bool = false,
                       constituents: [CameraLensCandidate] = rgb) -> MainCameraAuxiliaryCandidate {
            .init(id: id, kind: kind, isVirtual: true, rgbConstituents: constituents,
                  supportsExactPrimaryLock: locked)
        }
        let lidar = candidate("lidar", .lidar, constituents: [rgb[1]])
        let unlocked = candidate("dual-wide", .dualWide)
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [unlocked]).isEmpty,
              "旧系统不能凭变焦或当前场景选中未可精确锁定的双摄")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [unlocked, lidar]).map(\.id) == ["lidar"],
              "旧系统可用唯一 RGB 为选定主摄的 LiDAR 配对")
        let ordered = MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [
            lidar, candidate("triple", .triple, locked: true),
            candidate("dual", .dual, locked: true), candidate("dual-wide", .dualWide, locked: true)])
        check(ordered.map(\.id) == ["dual-wide", "dual", "triple", "lidar"],
              "可精确锁主摄时按旧版优先级探测立体原生深度")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [
            candidate("wrong", .dualWide, locked: true, constituents: [.init(id: "wide-B", kind: .wide, isVirtual: false)])]).isEmpty,
              "相同主摄类型但不同物理 ID 不能辅助当前主摄")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [
            candidate("wrong-kind", .dualWide, locked: true, constituents: [.init(id: "wide-A", kind: .telephoto, isVirtual: false)])]).isEmpty,
              "相同 ID 但镜头类型错误不能被认作主摄")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [
            candidate("virtual-rgb", .dualWide, locked: true, constituents: [.init(id: "wide-A", kind: .wide, isVirtual: true)])]).isEmpty,
              "RGB constituent 必须为真实物理主摄")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [candidate("invalid-lidar", .lidar)]).isEmpty,
              "LiDAR 配对若仍有可切换 RGB 镜头则拒绝")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [candidate("unknown-lidar", .lidar, constituents: [])]).isEmpty,
              "无法核实 LiDAR 配对身份时不能猜测主摄")
        for kind in [CameraLensKind.ultraWide, .telephoto] {
            check(MainCameraCapturePolicy.auxiliaries(for: .init(id: "wide-A", kind: kind), candidates: ordered).isEmpty,
                  "超广角与长焦永不接入原生辅助组合")
        }
        check(MainCameraCapturePolicy.nativeRawZoom(selectedID: "wide-A", constituentIDs: ["ultra", "wide-A", "tele"],
              switchOverFactors: [2, 10]) == 2, "虚拟 raw 2x 对应主摄本身的数码 1x")
        check(MainCameraCapturePolicy.nativeRawZoom(selectedID: "wide-A", constituentIDs: ["wide-A", "tele"],
              switchOverFactors: [3]) == 1, "双摄中的原生主摄保持 raw 1x")
        check(MainCameraCapturePolicy.nativeRawZoom(selectedID: "wide-A", constituentIDs: ["ultra", "wide-A"],
              switchOverFactors: []) == nil, "缺少视场倍率时不能假设虚拟 1x 为主摄 1x")
        check(MainCameraCapturePolicy.nativeRawZoom(selectedID: "wide-A", constituentIDs: ["ultra", "wide-A"],
              switchOverFactors: [.nan]) == nil, "无效视场倍率不得用于硬件配置")
        check(MainCameraCapturePolicy.nativeRawZoom(selectedID: "wide-A", constituentIDs: ["other"],
              switchOverFactors: []) == nil, "视场匹配也必须使用精确 ID")
        let sources: Set<String> = ["wide", "dual-wide"]
        check(MainCameraCapturePolicy.acceptsMainPhoto(sourceType: "dual-wide", expectedSourceTypes: sources, fusionEnabled: false),
              "虚拟输入的普通照片按 SDK 约定可报告虚拟 sourceDeviceType")
        check(MainCameraCapturePolicy.acceptsMainPhoto(sourceType: "wide", expectedSourceTypes: sources, fusionEnabled: false),
              "明确主摄来源的照片可以交付")
        check(!MainCameraCapturePolicy.acceptsMainPhoto(sourceType: "ultra", expectedSourceTypes: sources, fusionEnabled: false),
              "明确来自其他 RGB 镜头的照片必须拒绝")
        check(!MainCameraCapturePolicy.acceptsMainPhoto(sourceType: "unknown", expectedSourceTypes: sources, fusionEnabled: false),
              "无法核实来源的主摄照片不得作为已保证主摄交付")
        check(!MainCameraCapturePolicy.acceptsMainPhoto(sourceType: "dual-wide", expectedSourceTypes: sources, fusionEnabled: true),
              "主摄锁定也不能允许成片混入其他 RGB 镜头的融合图像")
        print("Main camera capture policy: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
