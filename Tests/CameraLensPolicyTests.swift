import Foundation

@main
struct CameraLensPolicyTests {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures += 1; print("FAIL: \(message)") }
        }
        let triple = CameraLensPolicy.options(candidates: [
            .init(id: "tele-device", kind: .telephoto, isVirtual: false),
            .init(id: "wide-device", kind: .wide, isVirtual: false),
            .init(id: "ultra-device", kind: .ultraWide, isVirtual: false)
        ])
        check(triple.map(\.id) == ["ultra-device", "wide-device", "tele-device"],
              "三个物理镜头按超广角、主摄、长焦排列")
        check(triple.map(\.title) == ["超广角", "主摄", "长焦"], "镜头按钮按物理类型命名")
        check(CameraLensPolicy.select(requestedID: nil, options: triple)?.id == "wide-device",
              "默认选主摄而非排列第一的超广角")
        check(CameraLensPolicy.select(requestedID: "tele-device", options: triple)?.kind == .telephoto,
              "显式选择使用精确物理镜头ID")
        check(CameraLensPolicy.select(requestedID: "missing-device", options: triple) == nil,
              "请求不存在镜头必须失败不能改切主摄")
        check(CameraLensPolicy.select(requestedID: "TELE-device", options: triple) == nil,
              "设备ID精确区分大小写")
        check(CameraLensPolicy.select(requestedID: "", options: triple) == nil,
              "空的显式请求不能当作默认选镜头")
        let physicalOnly = CameraLensPolicy.options(candidates: [
            .init(id: "virtual-wide", kind: .wide, isVirtual: true),
            .init(id: "physical-wide", kind: .wide, isVirtual: true),
            .init(id: "physical-wide", kind: .wide, isVirtual: false),
            .init(id: "", kind: .ultraWide, isVirtual: false),
            .init(id: "  \n", kind: .telephoto, isVirtual: false)
        ])
        check(physicalOnly.map(\.id) == ["physical-wide"], "排除虚拟相机与空ID而不漏掉同ID物理候选")
        check(CameraLensPolicy.select(requestedID: "virtual-wide", options: physicalOnly) == nil,
              "伪装主摄的虚拟组合无法被选为物理镜头")
        let single = CameraLensPolicy.options(candidates: [.init(id: "only-wide", kind: .wide, isVirtual: false)])
        check(single.count == 1 && single.first?.id == "only-wide", "单摄不虚构另外两个镜头")
        let dual = CameraLensPolicy.options(candidates: [
            .init(id: "tele", kind: .telephoto, isVirtual: false),
            .init(id: "ultra", kind: .ultraWide, isVirtual: false)
        ])
        check(dual.map(\.kind) == [.ultraWide, .telephoto], "双摄只提供实际发现的镜头")
        check(CameraLensPolicy.select(requestedID: nil, options: dual)?.id == "ultra",
              "没有主摄时默认第一个可用物理镜头")
        let sameKinds = CameraLensPolicy.options(candidates: [
            .init(id: "second-wide", kind: .wide, isVirtual: false),
            .init(id: "tele", kind: .telephoto, isVirtual: false),
            .init(id: "first-wide", kind: .wide, isVirtual: false),
            .init(id: "second-wide", kind: .wide, isVirtual: false)
        ])
        check(sameKinds.map(\.id) == ["second-wide", "first-wide", "tele"],
              "同类型不同物理ID均保留且稳定排序，相同ID去重")
        check(CameraLensPolicy.select(requestedID: "first-wide", options: sameKinds)?.id == "first-wide",
              "同类型镜头仍按选中ID绑定，不从镜头类型或数码倍率猜测")
        check(CameraLensPolicy.select(requestedID: nil, options: sameKinds)?.id == "second-wide",
              "多个主摄候选保持发现顺序")
        check(CameraLensPolicy.options(candidates: []).isEmpty, "无设备时无镜头按钮")
        check(CameraLensPolicy.select(requestedID: nil, options: []) == nil, "无设备时默认选择失败")
        check(CameraLensPolicy.select(requestedID: "wide", options: []) == nil, "无设备时显式选择失败")

        print("Camera lens policy: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
