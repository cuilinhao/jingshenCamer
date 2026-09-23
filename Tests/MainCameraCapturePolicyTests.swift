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
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [unlocked]).map(\.id) == ["dual-wide"],
              "旧系统允许探测双摄深度，运行后再验证并锁定实际主摄")
        check(MainCameraCapturePolicy.auxiliaries(for: wide, candidates: [unlocked, lidar]).map(\.id) == ["dual-wide", "lidar"],
              "旧系统按双摄和 LiDAR 顺序探测真实深度能力")
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
        check(MainCameraCapturePolicy.prefersAppleDepth(isFront: true, rearLensKind: nil),
              "前置优先原生深度和苹果滤镜")
        check(MainCameraCapturePolicy.prefersAppleDepth(isFront: false, rearLensKind: .wide),
              "主摄优先原生深度和苹果滤镜")
        for kind in [CameraLensKind.ultraWide, .telephoto] {
            check(!MainCameraCapturePolicy.prefersAppleDepth(isFront: false, rearLensKind: kind),
                  "其他后置镜头继续模型处理")
        }
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

        let exactPrimary = MainCameraPrimaryIdentity(id: "wide-A", rgbKind: .wide, isVirtual: false)
        let otherPrimary = MainCameraPrimaryIdentity(id: "wide-B", rgbKind: .wide, isVirtual: false)
        let depthPrimary = MainCameraPrimaryIdentity(id: "depth", rgbKind: nil, isVirtual: false)
        let dual = candidate("dual", .dual, locked: true)
        func rejection(_ input: MainCameraAuxiliaryCandidate?, configuredID: String = "lidar",
                       kind: MainCameraAuxiliaryKind = .lidar,
                       phase: MainCameraIdentityPhase = .capture,
                       primary: MainCameraPrimaryIdentity? = nil,
                       requestedLocked: Bool = false, activeLocked: Bool = false) -> MainCameraIdentityRejection? {
            MainCameraCapturePolicy.identityRejection(for: wide, configuredInputID: configuredID,
                configuredKind: kind, currentInput: input, phase: phase, primary: primary,
                requestedPrimaryLocked: requestedLocked, activePrimaryLocked: activeLocked)
        }
        for phase in [MainCameraIdentityPhase.configuration, .capture] {
            check(rejection(lidar, phase: phase) == nil,
                  "LiDAR 唯一物理 RGB 精确配对时配置和首次快门均不依赖尚未给出的 primary")
            check(rejection(lidar, phase: phase, primary: depthPrimary) == nil,
                  "LiDAR 的非 RGB primary 不推翻已核实的唯一物理 RGB 配对")
            check(rejection(lidar, phase: phase, primary: exactPrimary) == nil,
                  "LiDAR 明确报告所选物理主摄时允许使用")
            check(rejection(lidar, phase: phase, primary: otherPrimary) == .activePrimaryMismatch,
                  "LiDAR 明确指向其他物理 RGB 是矛盾证据，配置和快门均须拒绝")
        }
        check(rejection(lidar, configuredID: "previous-lidar") == .inputIDMismatch,
              "当前 LiDAR 输入必须是本次成功配置的同一个设备")
        check(rejection(dual, configuredID: "dual") == .inputKindMismatch,
              "不能将双摄输入误当作已经配置的 LiDAR")
        check(rejection(nil) == .currentInputNotAuxiliary,
              "实际输入已变成独立 RGB 时不可沿用 LiDAR 身份状态")
        check(rejection(candidate("lidar", .lidar, constituents: rgb)) == .lidarRGBCountInvalid,
              "LiDAR 实际有多颗 RGB 时不能根据其中一颗匹配而放行")
        check(rejection(candidate("lidar", .lidar, constituents: [])) == .selectedPhysicalWideMissing,
              "LiDAR 缺少可验证的物理 RGB 时须拒绝")
        check(rejection(candidate("lidar", .lidar, constituents: [
            .init(id: "wide-B", kind: .wide, isVirtual: false)])) == .selectedPhysicalWideMissing,
              "LiDAR 唯一 RGB 也必须匹配选定主摄 ID")
        check(rejection(candidate("lidar", .lidar, constituents: [
            .init(id: "wide-A", kind: .wide, isVirtual: true)])) == .selectedPhysicalWideMissing,
              "LiDAR 相同 ID 的虚拟 RGB 不构成物理主摄证明")
        check(rejection(lidar, primary: .init(id: "wide-A", rgbKind: .telephoto, isVirtual: false)) == .activePrimaryMismatch,
              "primary 即使 ID 相同，明确为不同 RGB 类型也必须拒绝")
        check(rejection(dual, configuredID: "dual", kind: .dual, phase: .configuration,
                        requestedLocked: true) == nil,
              "双摄配置事务尚未运行时不要求 activePrimary 已生效")
        check(rejection(dual, configuredID: "dual", kind: .dual, phase: .configuration) == .requestedPrimaryNotLocked,
              "双摄配置阶段必须已成功请求精确锁定")
        check(rejection(unlocked, configuredID: "dual-wide", kind: .dualWide, phase: .configuration) == nil,
              "旧系统配置时允许 primary 尚未出现，不因缺少 iOS 27 API 拒绝深度输入")
        check(rejection(unlocked, configuredID: "dual-wide", kind: .dualWide, primary: exactPrimary,
                        requestedLocked: true, activeLocked: true) == nil,
              "旧系统运行后匹配主摄并锁定当前 primary 可交付原生深度")
        check(rejection(unlocked, configuredID: "dual-wide", kind: .dualWide, primary: otherPrimary,
                        requestedLocked: true, activeLocked: true) == .activePrimaryMismatch,
              "旧锁定 API 不能把其他镜头冒充主摄")
        for kind in [MainCameraAuxiliaryKind.dualWide, .dual, .triple] {
            let input = candidate("stereo", kind, locked: true)
            check(rejection(input, configuredID: "stereo", kind: kind, primary: exactPrimary,
                            requestedLocked: true, activeLocked: true) == nil,
                  "可切 RGB 组合在快门时须精确 primary 与请求/活动锁定全部成立")
            check(rejection(input, configuredID: "stereo", kind: kind,
                            requestedLocked: true, activeLocked: true) == .activePrimaryMissing,
                  "双/三摄首次快门和恢复后不能凭配置锁定放过缺失 primary")
            check(rejection(input, configuredID: "stereo", kind: kind, primary: exactPrimary,
                            requestedLocked: true) == .activePrimaryNotLocked,
                  "双/三摄只请求锁定但活动锁定丢失时必须恢复")
            check(rejection(input, configuredID: "stereo", kind: kind, primary: exactPrimary,
                            activeLocked: true) == .requestedPrimaryNotLocked,
                  "双/三摄当前正确但未锁定仍可能切镜头，不能放行")
            check(rejection(input, configuredID: "stereo", kind: kind, primary: depthPrimary,
                            requestedLocked: true, activeLocked: true) == .activePrimaryNotPhysicalRGB,
                  "双/三摄必须明确报告物理 RGB primary")
            check(rejection(input, configuredID: "stereo", kind: kind, primary: otherPrimary,
                            requestedLocked: true, activeLocked: true) == .activePrimaryMismatch,
                  "双/三摄活动 primary 的物理 ID 不同必须拒绝")
        }
        check(rejection(dual, configuredID: "dual", kind: .dual,
                        primary: .init(id: "wide-A", rgbKind: .wide, isVirtual: true),
                        requestedLocked: true, activeLocked: true) == .activePrimaryNotPhysicalRGB,
              "双摄的虚拟 primary 不能冒充所选物理主摄")
        for attempted in [false, true] {
            check(MainCameraCapturePolicy.captureRecovery(for: nil, auxiliaryKind: .lidar,
                supportsExactPrimaryLock: false, relockAttempted: attempted) == .useCurrentInput,
                  "有效 LiDAR 首次或恢复后直接拍照，不每次快门重配")
            check(MainCameraCapturePolicy.captureRecovery(for: .activePrimaryMismatch, auxiliaryKind: .lidar,
                supportsExactPrimaryLock: true, relockAttempted: attempted) == .restorePhysicalMain,
                  "矛盾 LiDAR 不尝试切换 RGB，通过独立主摄保障身份并保留智能回退")
        }
        check(MainCameraCapturePolicy.captureRecovery(for: .activePrimaryMissing, auxiliaryKind: .dual,
            supportsExactPrimaryLock: true, relockAttempted: false) == .relockExactPrimary,
              "双摄活动身份未生效或恢复后丢失时只重新精确锁定一次")
        check(MainCameraCapturePolicy.captureRecovery(for: nil, auxiliaryKind: .dual,
            supportsExactPrimaryLock: true, relockAttempted: true) == .useCurrentInput,
              "重新锁定通过验证后直接拍照，保留原生深度输入")
        check(MainCameraCapturePolicy.captureRecovery(for: .activePrimaryMissing, auxiliaryKind: .dual,
            supportsExactPrimaryLock: true, relockAttempted: true) == .restorePhysicalMain,
              "重新锁定仍失败后降级，不循环重试")
        check(MainCameraCapturePolicy.captureRecovery(for: .activePrimaryMissing, auxiliaryKind: .dual,
            supportsExactPrimaryLock: false, relockAttempted: false) == .restorePhysicalMain,
              "旧系统 primary 缺失时不能猜测当前镜头，回独立主摄")
        check(MainCameraCapturePolicy.captureRecovery(for: .inputIDMismatch, auxiliaryKind: .dual,
            supportsExactPrimaryLock: true, relockAttempted: false) == .restorePhysicalMain,
              "结构性输入身份错误不能尝试在错误设备上锁定")
        for reason in [MainCameraIdentityRejection.requestedPrimaryNotLocked, .activePrimaryNotLocked] {
            check(MainCameraCapturePolicy.captureRecovery(for: reason, auxiliaryKind: .dualWide,
                supportsExactPrimaryLock: false, primaryMatchesSelected: true,
                relockAttempted: false) == .lockCurrentPrimary,
                  "旧系统当前确为所选主摄时尝试锁定当前 primary")
            check(MainCameraCapturePolicy.captureRecovery(for: reason, auxiliaryKind: .dualWide,
                supportsExactPrimaryLock: false, primaryMatchesSelected: false,
                relockAttempted: false) == .restorePhysicalMain,
                  "旧系统不能通过锁定错误或未知 primary 猜测主摄")
            check(MainCameraCapturePolicy.captureRecovery(for: reason, auxiliaryKind: .dualWide,
                supportsExactPrimaryLock: false, primaryMatchesSelected: true,
                relockAttempted: true) == .restorePhysicalMain,
                  "旧系统锁定失败后降级，不循环重试")
        }
        print("Main camera capture policy: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
