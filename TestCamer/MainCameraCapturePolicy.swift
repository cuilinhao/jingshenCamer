import Foundation

enum MainCameraAuxiliaryKind: Int, CaseIterable, Sendable {
    case dualWide, dual, triple, lidar
}

struct MainCameraAuxiliaryCandidate: Sendable {
    let id: String
    let kind: MainCameraAuxiliaryKind
    let isVirtual: Bool
    let rgbConstituents: [CameraLensCandidate]
    let supportsExactPrimaryLock: Bool
}

struct MainCameraPrimaryIdentity: Sendable {
    let id: String
    /// nil 表示深度等非 RGB 设备，不能据此推断另一个物理 RGB 正在成像。
    let rgbKind: CameraLensKind?
    let isVirtual: Bool
}

enum MainCameraIdentityPhase: Sendable {
    case configuration, capture
}

enum MainCameraIdentityRejection: String, Sendable {
    case selectedLensNotWide, currentInputNotAuxiliary, inputIDMismatch, inputKindMismatch
    case inputNotVirtual, selectedPhysicalWideMissing, lidarRGBCountInvalid, exactPrimaryLockUnsupported
    case requestedPrimaryNotLocked, activePrimaryMissing, activePrimaryNotPhysicalRGB
    case activePrimaryMismatch, activePrimaryNotLocked
}

enum MainCameraCaptureRecovery: Sendable {
    case useCurrentInput, relockExactPrimary, restorePhysicalMain
}

enum MainCameraCapturePolicy {
    static func acceptsMainPhoto(sourceType: String, expectedSourceTypes: Set<String>, fusionEnabled: Bool) -> Bool {
        !fusionEnabled && expectedSourceTypes.contains(sourceType)
    }

    static func auxiliaries(for selected: CameraLensOption,
                            candidates: [MainCameraAuxiliaryCandidate]) -> [MainCameraAuxiliaryCandidate] {
        candidates.filter { auxiliaryRejection(for: selected, candidate: $0) == nil }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    static func auxiliaryRejection(for selected: CameraLensOption,
                                   candidate: MainCameraAuxiliaryCandidate) -> MainCameraIdentityRejection? {
        guard selected.kind == .wide else { return .selectedLensNotWide }
        guard candidate.isVirtual else { return .inputNotVirtual }
        guard candidate.rgbConstituents.contains(where: {
            $0.id == selected.id && $0.kind == .wide && !$0.isVirtual
        }) else { return .selectedPhysicalWideMissing }
        if candidate.kind == .lidar {
            return candidate.rgbConstituents.count == 1 ? nil : .lidarRGBCountInvalid
        }
        return candidate.supportsExactPrimaryLock ? nil : .exactPrimaryLockUnsupported
    }

    /// 配置与快门共用配对规则；配置事务中不要求尚未运行的 active-primary 状态已生效。
    static func identityRejection(for selected: CameraLensOption, configuredInputID: String,
                                  configuredKind: MainCameraAuxiliaryKind,
                                  currentInput: MainCameraAuxiliaryCandidate?, phase: MainCameraIdentityPhase,
                                  primary: MainCameraPrimaryIdentity?, requestedPrimaryLocked: Bool,
                                  activePrimaryLocked: Bool) -> MainCameraIdentityRejection? {
        guard let input = currentInput else { return .currentInputNotAuxiliary }
        guard input.id == configuredInputID else { return .inputIDMismatch }
        guard input.kind == configuredKind else { return .inputKindMismatch }
        if let rejection = auxiliaryRejection(for: selected, candidate: input) { return rejection }
        if input.kind == .lidar {
            // 唯一物理 RGB 配对已经证明身份；只有明确的另一颗物理 RGB 才构成矛盾。
            guard let primary, !primary.isVirtual, primary.rgbKind != nil else { return nil }
            return primary.id == selected.id && primary.rgbKind == .wide ? nil : .activePrimaryMismatch
        }
        guard requestedPrimaryLocked else { return .requestedPrimaryNotLocked }
        if phase == .configuration { return nil }
        guard let primary else { return .activePrimaryMissing }
        guard !primary.isVirtual, primary.rgbKind != nil else { return .activePrimaryNotPhysicalRGB }
        guard primary.id == selected.id, primary.rgbKind == .wide else { return .activePrimaryMismatch }
        return activePrimaryLocked ? nil : .activePrimaryNotLocked
    }

    static func captureRecovery(for rejection: MainCameraIdentityRejection?,
                                auxiliaryKind: MainCameraAuxiliaryKind, supportsExactPrimaryLock: Bool,
                                relockAttempted: Bool) -> MainCameraCaptureRecovery {
        guard let rejection else { return .useCurrentInput }
        guard auxiliaryKind != .lidar, supportsExactPrimaryLock, !relockAttempted else {
            return .restorePhysicalMain
        }
        switch rejection {
        case .requestedPrimaryNotLocked, .activePrimaryMissing, .activePrimaryNotPhysicalRGB,
             .activePrimaryMismatch, .activePrimaryNotLocked:
            return .relockExactPrimary
        default:
            return .restorePhysicalMain
        }
    }

    static func nativeRawZoom(selectedID: String, constituentIDs: [String],
                              switchOverFactors: [Double]) -> Double? {
        guard let index = constituentIDs.firstIndex(of: selectedID) else { return nil }
        if index == 0 { return 1 }
        guard switchOverFactors.indices.contains(index - 1) else { return nil }
        let factor = switchOverFactors[index - 1]
        return factor.isFinite && factor >= 1 ? factor : nil
    }
}
