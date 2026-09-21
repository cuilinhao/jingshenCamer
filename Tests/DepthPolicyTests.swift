import Foundation

@main
struct DepthPolicyTests {
    static func main() {
        var count = 0
        func check(_ ok: @autoclosure () -> Bool, _ name: String) {
            guard ok() else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS: \(name)")
        }
        check(DepthCapturePolicy.aperture(sliderValue: 0) == 1.4, "最小虚拟光圈")
        check(DepthCapturePolicy.aperture(sliderValue: 1) == 1.8, "默认虚拟光圈")
        check(DepthCapturePolicy.aperture(sliderValue: -10) == 1.4, "slider 下界")
        check(DepthCapturePolicy.aperture(sliderValue: 100) == 16, "slider 上界")
        check(DepthCapturePolicy.aperture(sliderValue: .nan) == 1.8, "slider NaN")
        check(DepthCapturePolicy.aperture(sliderValue: .infinity) == 1.8, "slider infinity")
        check(DepthOptions(enabled: true, aperture: 0).aperture == 1.4, "f 值夹取下界")
        check(DepthOptions(enabled: true, aperture: 100).aperture == 16, "f 值夹取上界")
        check(DepthOptions(enabled: true, aperture: .nan).aperture == 1.8, "f 值 NaN")
        check(!DepthOptions(enabled: false, aperture: 1.8).enabled, "用户可关闭景深")
        check(DepthCapturePolicy.clampedZoom(1, minimum: 2, maximum: 8) == 2, "深度模式不能写低于硬件下限的变焦")
        check(DepthCapturePolicy.clampedZoom(20, minimum: 2, maximum: 4) == 4, "硬件变焦上限")
        check(DepthCapturePolicy.clampedZoom(20, minimum: 10, maximum: 20) == 10, "用户缩放上限不能低于硬件最小值")
        check(DepthCapturePolicy.clampedZoom(.nan, minimum: 2, maximum: 4) == 2, "变焦 NaN")
        check(DepthCapturePolicy.clampedZoom(2, minimum: 1, maximum: 4) == 2, "合法变焦不变")
        check(DepthCapturePolicy.usableDepth(valid: 90, total: 100, minimum: 0.2, maximum: 2), "有效分层深度")
        check(!DepthCapturePolicy.usableDepth(valid: 0, total: 100, minimum: 0, maximum: 0), "空深度不能假成功")
        check(!DepthCapturePolicy.usableDepth(valid: 10, total: 100, minimum: 0.2, maximum: 2), "过多无效深度")
        check(!DepthCapturePolicy.usableDepth(valid: 100, total: 100, minimum: 1, maximum: 1), "无分层深度")
        check(!DepthCapturePolicy.usableDepth(valid: 100, total: 100, minimum: .nan, maximum: 1), "NaN 深度")
        check(!DepthCapturePolicy.usableDepth(valid: 100, total: 100, minimum: -1, maximum: 1), "无效负视差")
        check(DepthRenderOutcome.applied.isDepthApplied, "景深成功状态")
        check(!DepthRenderOutcome.missingDepth.isDepthApplied, "缺深度不能显示为景深成功")
        check(!DepthRenderOutcome.unsupported.isDepthApplied, "旧机型保留普通拍照")
        check(!DepthRenderOutcome.renderFailed.isDepthApplied, "渲染失败不伪装成功")
        print("\n\(count) policy checks passed.")
    }
}
