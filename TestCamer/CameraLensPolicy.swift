import Foundation

enum CameraLensKind: String, CaseIterable, Sendable {
    case ultraWide, wide, telephoto

    var title: String {
        switch self {
        case .ultraWide: return "超广角"
        case .wide: return "主摄"
        case .telephoto: return "长焦"
        }
    }
}

struct CameraLensCandidate: Sendable {
    let id: String
    let kind: CameraLensKind
    let isVirtual: Bool
}

struct CameraLensOption: Sendable, Equatable, Identifiable {
    let id: String
    let kind: CameraLensKind
    var title: String { kind.title }
}

enum CameraLensPolicy {
    /// 仅列出真实物理镜头；同类型的不同设备仍保留各自的唯一身份。
    static func options(candidates: [CameraLensCandidate]) -> [CameraLensOption] {
        var seenIDs: Set<String> = []
        let physical = candidates.filter {
            !$0.isVirtual && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seenIDs.insert($0.id).inserted
        }
        return CameraLensKind.allCases.flatMap { kind in
            physical.filter { $0.kind == kind }.map { CameraLensOption(id: $0.id, kind: kind) }
        }
    }

    /// 显式请求不能自动替换为另一镜头；默认选择仅在未指定 ID 时使用。
    static func select(requestedID: String?, options: [CameraLensOption]) -> CameraLensOption? {
        if let requestedID { return options.first { $0.id == requestedID } }
        return options.first { $0.kind == .wide } ?? options.first
    }
}
