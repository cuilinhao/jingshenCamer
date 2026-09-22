import Foundation

@main
struct CameraZoomPolicyTests {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        // 这些场景必须保持用户构图；缺深度时不能偷偷跳到另一个合法深度倍率。
        let discrete: [ClosedRange<Double>] = [2...2, 8...8]
        let gap = CameraZoomPolicy.plan(requestedRawZoom: 5, maximumRawZoom: 30,
            displayMultiplier: 0.5, depthAvailable: true, depthRanges: discrete)
        check(gap.rawZoomFactor == 5 && !gap.depthEnabled, "离散深度档位的空隙关闭深度但保持倍率")
        let stop = CameraZoomPolicy.plan(requestedRawZoom: 8, maximumRawZoom: 30,
            displayMultiplier: 0.5, depthAvailable: true, depthRanges: discrete)
        check(stop.rawZoomFactor == 8 && stop.depthEnabled, "恰好位于离散档位可开启深度")
        let fiveTimes = CameraZoomPolicy.plan(requestedRawZoom: 10, maximumRawZoom: 30,
            displayMultiplier: 0.5, depthAvailable: false, depthRanges: [])
        check(fiveTimes.rawZoomFactor == 10, "显示5倍的原始10倍可正常取景")
        let userLimit = CameraZoomPolicy.plan(requestedRawZoom: 30, maximumRawZoom: 30,
            displayMultiplier: 0.5, depthAvailable: false, depthRanges: [])
        check(userLimit.rawZoomFactor == 16, "8倍上限按显示倍率换算")
        let hardwareLimit = CameraZoomPolicy.plan(requestedRawZoom: 30, maximumRawZoom: 12,
            displayMultiplier: 0.5, depthAvailable: false, depthRanges: [])
        check(hardwareLimit.rawZoomFactor == 12, "倍率同时受真实硬件上限约束")
        let continuous: [ClosedRange<Double>] = [2...5]
        for value in [2.0, 3.7, 5.0] {
            let plan = CameraZoomPolicy.plan(requestedRawZoom: value, maximumRawZoom: 20,
                displayMultiplier: 0.5, depthAvailable: true, depthRanges: continuous)
            check(plan.rawZoomFactor == value && plan.depthEnabled, "连续范围包含两端点和中间倍率")
        }
        for value in [1.5, 5.00001] {
            let plan = CameraZoomPolicy.plan(requestedRawZoom: value, maximumRawZoom: 20,
                displayMultiplier: 0.5, depthAvailable: true, depthRanges: continuous)
            check(plan.rawZoomFactor == value && !plan.depthEnabled, "真实范围外倍率不以宽容差冒充可用深度")
        }
        for (value, endpoint) in [(2.0 - 0.00000005, 2.0), (5.0 + 0.00000005, 5.0)] {
            let plan = CameraZoomPolicy.plan(requestedRawZoom: value, maximumRawZoom: 20,
                displayMultiplier: 0.5, depthAvailable: true, depthRanges: continuous)
            check(plan.rawZoomFactor == endpoint && plan.depthEnabled, "浮点重算微差先吸附合法端点再开启深度")
        }
        let tinyHardwareLimit = CameraZoomPolicy.plan(requestedRawZoom: 3, maximumRawZoom: 2.0 - 0.00000005,
            displayMultiplier: 0.5, depthAvailable: true, depthRanges: discrete)
        check(tinyHardwareLimit.rawZoomFactor == 2.0 - 0.00000005 && !tinyHardwareLimit.depthEnabled,
              "端点吸附不能越过硬件上限")
        for (available, ranges) in [(false, continuous), (true, [])] {
            let plan = CameraZoomPolicy.plan(requestedRawZoom: 3, maximumRawZoom: 10,
                displayMultiplier: 1, depthAvailable: available, depthRanges: ranges)
            check(plan.rawZoomFactor == 3 && !plan.depthEnabled, "设备或范围缺失时保留倍率并禁用深度")
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            let plan = CameraZoomPolicy.plan(requestedRawZoom: invalid, maximumRawZoom: 20,
                displayMultiplier: 0.5, depthAvailable: true, depthRanges: continuous)
            check(plan.rawZoomFactor == 1 && !plan.depthEnabled, "非有限请求恢复安全原始1倍")
        }
        let belowMinimum = CameraZoomPolicy.plan(requestedRawZoom: -4, maximumRawZoom: 20,
            displayMultiplier: 0.5, depthAvailable: false, depthRanges: [])
        check(belowMinimum.rawZoomFactor == 1, "负倍率夹取到硬件基本下界")
        for invalid in [Double.nan, .infinity, 0, -1] {
            let plan = CameraZoomPolicy.plan(requestedRawZoom: 20, maximumRawZoom: invalid,
                displayMultiplier: 1, depthAvailable: false, depthRanges: [])
            check(plan.rawZoomFactor == 1, "非法硬件上限只允许安全1倍")
            let multiplierPlan = CameraZoomPolicy.plan(requestedRawZoom: 20, maximumRawZoom: 30,
                displayMultiplier: invalid, depthAvailable: false, depthRanges: [])
            check(multiplierPlan.rawZoomFactor == 8, "非法显示比例回退为1而不产生非法硬件倍率")
        }
        let largeMultiplier = CameraZoomPolicy.plan(requestedRawZoom: 3, maximumRawZoom: 10,
            displayMultiplier: 20, depthAvailable: false, depthRanges: [])
        check(largeMultiplier.rawZoomFactor == 1, "显示上限换算不能产生小于1的硬件上限")
        let invalidRanges = CameraZoomPolicy.plan(requestedRawZoom: 3, maximumRawZoom: 10,
            displayMultiplier: 1, depthAvailable: true, depthRanges: [-Double.infinity...Double.infinity])
        check(!invalidRanges.depthEnabled, "非有限深度范围不能宣称支持")

        print("Camera zoom policy: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
