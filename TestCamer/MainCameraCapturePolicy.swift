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

enum MainCameraCapturePolicy {
    static func acceptsMainPhoto(sourceType: String, expectedSourceTypes: Set<String>, fusionEnabled: Bool) -> Bool {
        !fusionEnabled && expectedSourceTypes.contains(sourceType)
    }

    static func auxiliaries(for selected: CameraLensOption,
                            candidates: [MainCameraAuxiliaryCandidate]) -> [MainCameraAuxiliaryCandidate] {
        guard selected.kind == .wide else { return [] }
        return candidates.filter { candidate in
            guard candidate.isVirtual,
                  candidate.rgbConstituents.contains(where: {
                      $0.id == selected.id && $0.kind == .wide && !$0.isVirtual
                  }) else { return false }
            // LiDAR 只有这一颗 RGB，深度相机不参与 RGB 主镜头切换。
            if candidate.kind == .lidar { return candidate.rgbConstituents.count == 1 }
            return candidate.supportsExactPrimaryLock
        }.sorted { $0.kind.rawValue < $1.kind.rawValue }
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
