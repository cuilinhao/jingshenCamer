import Foundation

struct CameraZoomPlan: Sendable, Equatable {
    let rawZoomFactor: Double
    let depthEnabled: Bool
}

enum CameraZoomPolicy {
    /// 不支持深度的倍率保留构图并关闭深度，不能跳到另一档来假装支持。
    static func plan(requestedRawZoom: Double, maximumRawZoom: Double, displayMultiplier: Double,
                     depthAvailable: Bool, depthRanges: [ClosedRange<Double>]) -> CameraZoomPlan {
        let multiplier = displayMultiplier.isFinite && displayMultiplier > 0 ? displayMultiplier : 1
        let hardwareMaximum = maximumRawZoom.isFinite ? max(1, maximumRawZoom) : 1
        let upper = max(1, min(hardwareMaximum, 8 / multiplier))
        let requested = requestedRawZoom.isFinite ? requestedRawZoom : 1
        let raw = min(upper, max(1, requested))
        guard depthAvailable else { return CameraZoomPlan(rawZoomFactor: raw, depthEnabled: false) }
        let ranges = depthRanges.filter {
            $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound > 0
        }
        if ranges.contains(where: { $0.contains(raw) }) {
            return CameraZoomPlan(rawZoomFactor: raw, depthEnabled: true)
        }
        // 仅修正倍率换算的浮点舍入；最终赋给相机的值必须真的位于合法范围。
        let endpoints: [Double] = ranges.flatMap { [$0.lowerBound, $0.upperBound] }
        let nearby = endpoints.filter { $0 >= 1 && $0 <= upper && abs($0 - raw) <= 0.0000001 }
        let endpoint = nearby.min { abs($0 - raw) < abs($1 - raw) }
        if let endpoint {
            return CameraZoomPlan(rawZoomFactor: endpoint, depthEnabled: true)
        }
        return CameraZoomPlan(rawZoomFactor: raw, depthEnabled: false)
    }
}
