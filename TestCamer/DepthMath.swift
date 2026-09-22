//
// DepthMath.swift — 纯 Swift 数值部分，不依赖相机、Core Image 或 UIKit。
// 视差越大越近；不把相对视差当作精确米数，不把 unknown 当背景。
// 原始传感器点位可随本机可编辑照片保存，用于拍后重渲染。
//
import Foundation

struct NormalizedImagePoint: Sendable, Equatable, Codable {
    /// 左上原点、完整图像归一化坐标；不是屏幕像素。
    let x: Double
    let y: Double
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }

    func oriented(exif: UInt32) -> Self {
        switch exif {
        case 2: return Self(x: 1-x, y: y)
        case 3: return Self(x: 1-x, y: 1-y)
        case 4: return Self(x: x, y: 1-y)
        case 5: return Self(x: y, y: x)
        case 6: return Self(x: 1-y, y: x)
        case 7: return Self(x: 1-y, y: 1-x)
        case 8: return Self(x: y, y: 1-x)
        default: return self
        }
    }
}

enum DepthAnalysisError: Error, LocalizedError, Equatable {
    case invalidBuffer, insufficientDepth, insufficientSeparation, focusUnavailable, alignmentMismatch
    var errorDescription: String? {
        switch self {
        case .invalidBuffer: return "深度数据格式或尺寸不正确"
        case .insufficientDepth: return "有效深度不足，未添加虚化"
        case .insufficientSeparation: return "当前画面前后深度差不足，未强行虚化"
        case .focusUnavailable: return "所选区域没有可靠深度，请点选主体内部后重拍"
        case .alignmentMismatch: return "照片与深度图比例不匹配，已停止错误对齐"
        }
    }
}

struct DepthRaster: Sendable {
    let width: Int
    let height: Int
    /// 从左到右、从上到下；已经去掉 CVPixelBuffer 行填充字节。
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              values.count == width * height else { throw DepthAnalysisError.invalidBuffer }
        self.width = width; self.height = height; self.values = values
    }

    func value(at point: NormalizedImagePoint) -> Float? {
        guard point.isValid else { return nil }
        let x = min(width-1, Int(point.x * Double(width)))
        let y = min(height-1, Int(point.y * Double(height)))
        let value = values[y*width+x]
        return value.isFinite && value > 0 ? value : nil
    }

    func oriented(exif: UInt32) -> Self {
        guard (2...8).contains(exif) else { return self }
        let swapped = exif >= 5
        let w = swapped ? height : width
        let h = swapped ? width : height
        var output = [Float](repeating: .nan, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                let dx: Int, dy: Int
                switch exif {
                case 2: (dx, dy) = (width-1-x, y)
                case 3: (dx, dy) = (width-1-x, height-1-y)
                case 4: (dx, dy) = (x, height-1-y)
                case 5: (dx, dy) = (y, x)
                case 6: (dx, dy) = (height-1-y, x)
                case 7: (dx, dy) = (height-1-y, width-1-x)
                case 8: (dx, dy) = (y, width-1-x)
                default: (dx, dy) = (x, y)
                }
                output[dy*w+dx] = values[y*width+x]
            }
        }
        // 尺寸只交换，已在初始化时验证上限和数组长度。
        return Self(validatedWidth: w, height: h, values: output)
    }

    private init(validatedWidth: Int, height: Int, values: [Float]) {
        self.width = validatedWidth; self.height = height; self.values = values
    }
}

struct DepthPlan: Sendable {
    let width: Int
    let height: Int
    /// 0 为清晰，1 为当前虚拟光圈的最大虚化半径。两者不会同时非零。
    let near: [Float]
    let far: [Float]
    let validFraction: Double
    let nearFraction: Double
    let farFraction: Double
    let aperture: Float
    /// Only computational rendering supplies a selected instance. The interval
    /// is learned from its reliable interior, not a full-person sharp cutout.
    let subjectFocusRange: ClosedRange<Float>?

    var blurAmount: [Float] { zip(near, far).map { max($0, $1) } }
    func maxRadius(longEdge: Float) -> Float { DepthMath.radius(aperture: aperture, longEdge: longEdge) }
}

enum DepthMath {
    /// 这是视觉效果标定表，不是镜头的真实光学光圈。半径以 1600 px 长边为基准。
    private static let radiusAt1600: [Float] = [32, 25, 22, 16, 11, 7, 4, 2, 0.8]

    static func radius(aperture: Float, longEdge: Float) -> Float {
        let f = DepthOptions(enabled: true, aperture: aperture).aperture
        let fs = DepthCapturePolicy.apertures
        guard longEdge.isFinite, longEdge > 0 else { return 0 }
        var r = radiusAt1600[radiusAt1600.count-1]
        for i in 1..<fs.count where f <= fs[i] {
            let t = (f-fs[i-1]) / (fs[i]-fs[i-1])
            r = radiusAt1600[i-1] + (radiusAt1600[i]-radiusAt1600[i-1])*t
            break
        }
        return r * longEdge / 1600
    }

    static func makePlan(depth: DepthRaster, focus: NormalizedImagePoint?,
                         isPerson: Bool, aperture: Float,
                         selectedSubjectConfidence: [Float]? = nil,
                         selectedSubjectFace: NormalizedImagePoint? = nil) throws -> DepthPlan {
        guard selectedSubjectConfidence.map({ $0.count == depth.values.count }) ?? true else {
            throw DepthAnalysisError.invalidBuffer
        }
        let valid = depth.values.filter { $0.isFinite && $0 > 0 }.sorted()
        let fraction = Double(valid.count) / Double(depth.values.count)
        guard valid.count >= 9, fraction >= 0.25 else { throw DepthAnalysisError.insufficientDepth }
        let low = quantile(valid, 0.02), high = quantile(valid, 0.98)
        let span = high-low
        // 相对视差允许未知的整体偏移，不能以 median 或焦点值为分母。
        // 用同一张图的稳健视差跨度判断层次，并与局部噪声比较；整图加同一个
        // 偏移不会把平坦噪声变成可用深度，也不会让原本有效的场景被误拒绝。
        guard span > max(0.02, localNoise(in: depth) * 6) else {
            throw DepthAnalysisError.insufficientSeparation
        }
        // 小而平滑的视差坡度也可能只是平面估计误差，不能随跨度趋近零而
        // 被自动放大到最大虚化。0.25 是保守的视觉标定下限，不代表精确距离。
        // 下限和差值均不依赖视差零点，因此保留整体偏移不变性。
        let disparityScale = max(0.25, span * 0.5)
        let point = focus ?? NormalizedImagePoint(x: 0.5, y: 0.5)
        guard point.isValid, let focal = robustFocus(depth, at: point, disparityScale: disparityScale), focal > 0 else {
            throw DepthAnalysisError.focusUnavailable
        }
        let f = DepthOptions(enabled: true, aperture: aperture).aperture
        // 人脸用于选取深度平面/略放宽清晰带，而非把整张人像抠出来。
        // 同一深度的椅背、桌面、另一个物体照样保持清晰。
        let clearBand: Float = (isPerson ? 0.11 : 0.055) + (f-1.4)/14.6 * 0.15
        let subjectRange = selectedSubjectConfidence.flatMap {
            subjectFocusRange(in: depth, confidence: $0, point: point, focal: focal,
                              disparityScale: disparityScale, clearBand: clearBand,
                              face: selectedSubjectFace)
        }
        let transition: Float = 0.55
        var near = [Float](repeating: 0, count: depth.values.count)
        var far = near
        var nearCount = 0, farCount = 0
        for i in depth.values.indices {
            let d = depth.values[i]
            // 无效深度保持原图；不会把 NaN/0/负值识别成最远背景。
            guard d.isFinite, d > 0 else { continue }
            // 这是在当前场景稳健跨度上标定的视觉效果量，不是到主体的距离比例。
            // AVDepthData.relative 可含视差偏移；仅差值和跨度对该偏移不敏感。
            let signedDifference = (d-focal) / disparityScale
            var distance = abs(signedDifference)
            if let subjectRange, let confidence = selectedSubjectConfidence?[i], confidence.isFinite {
                // Uncertain/background alpha cannot expand the interval. A soft
                // transition avoids a hard depth discontinuity at the matte edge.
                let weight = min(1, max(0, (confidence-0.5)/0.4))
                let subjectDistance = max(0, subjectRange.lowerBound-d, d-subjectRange.upperBound) / disparityScale
                distance -= max(0, distance-subjectDistance) * weight
            }
            let linear = min(1, max(0, (distance-clearBand) / transition))
            let amount = pow(linear, 0.85)
            if signedDifference > 0 {
                near[i] = amount
                if amount > 0.08 { nearCount += 1 }
            } else {
                far[i] = amount
                if amount > 0.08 { farCount += 1 }
            }
        }
        return DepthPlan(width: depth.width, height: depth.height, near: near, far: far,
                         validFraction: fraction,
                         nearFraction: Double(nearCount)/Double(depth.values.count),
                         farFraction: Double(farCount)/Double(depth.values.count), aperture: f,
                         subjectFocusRange: subjectRange)
    }

    private static func subjectFocusRange(in depth: DepthRaster, confidence: [Float],
                                          point: NormalizedImagePoint, focal: Float,
                                          disparityScale: Float, clearBand: Float,
                                          face: NormalizedImagePoint?) -> ClosedRange<Float>? {
        let x = min(depth.width-1, Int(point.x*Double(depth.width)))
        let y = min(depth.height-1, Int(point.y*Double(depth.height)))
        guard confidence[y*depth.width+x].isFinite, confidence[y*depth.width+x] >= 0.9 else { return nil }
        let interior = depth.values.indices.compactMap { i -> Float? in
            let d = depth.values[i], alpha = confidence[i]
            return alpha.isFinite && alpha >= 0.9 && d.isFinite && d > 0 ? d : nil
        }.sorted()
        guard interior.count >= 9 else { return nil }
        var low = quantile(interior, 0.1), high = quantile(interior, 0.9)
        let limit = disparityScale * 0.6
        // A real face can occupy less than 10% of a full-body instance. Its
        // verified depth anchors the core before testing whether the tap belongs
        // to it, so both sleeve and face taps work. This never admits a face from
        // another instance, uncertain matte pixels, holes, or a distant plane.
        if let face, face.isValid {
            let fx = min(depth.width-1, Int(face.x*Double(depth.width)))
            let fy = min(depth.height-1, Int(face.y*Double(depth.height)))
            let alpha = confidence[fy*depth.width+fx]
            if alpha.isFinite, alpha >= 0.9, depth.value(at: face) != nil,
               let d = robustFocus(depth, at: face, disparityScale: disparityScale),
               abs(d-focal) <= limit {
                low = min(low, d); high = max(high, d)
            }
        }
        // The central 80% rejects fringe depths and isolated outliers. A focus
        // on an extended hand/object outside the body still selects that plane.
        let tolerance = clearBand * disparityScale
        guard focal >= low-tolerance, focal <= high+tolerance else { return nil }
        // Bound adaptation by scene depth, even if an instance contains a long
        // depth range. Never extend the interval to all depths in the matte.
        return min(focal, max(low, focal-limit))...max(focal, min(high, focal+limit))
    }

    /// 小片区内的中位数。中心有有效深度时，优先同一深度簇，减少跨物体边界混采。
    private static func robustFocus(_ map: DepthRaster, at point: NormalizedImagePoint,
                                    disparityScale: Float) -> Float? {
        let cx = min(map.width-1, Int(point.x*Double(map.width)))
        let cy = min(map.height-1, Int(point.y*Double(map.height)))
        let radius = max(1, min(map.width, map.height)/50)
        var patch: [Float] = []
        var total = 0
        for y in max(0, cy-radius)...min(map.height-1, cy+radius) {
            for x in max(0, cx-radius)...min(map.width-1, cx+radius) {
                total += 1
                let v = map.values[y*map.width+x]
                if v.isFinite && v > 0 { patch.append(v) }
            }
        }
        guard patch.count >= max(3, total/2) else { return nil }
        if let seed = map.value(at: point) {
            let cluster = patch.filter { abs($0-seed) < disparityScale*0.18 }
            if cluster.count >= max(3, total/3) { patch = cluster }
        }
        patch.sort()
        return quantile(patch, 0.5)
    }

    /// 相邻有效像素差的中位数。规则采样限制开销，零差也保留，不能把少数
    /// 真实物体边缘当作整张图的噪声；只比较差值，不依赖视差的绝对零点。
    private static func localNoise(in map: DepthRaster) -> Float {
        let step = max(1, min(map.width, map.height)/128)
        var differences: [Float] = []
        for y in stride(from: 0, to: map.height, by: step) {
            for x in stride(from: 0, to: map.width, by: step) {
                let value = map.values[y*map.width+x]
                guard value.isFinite, value > 0 else { continue }
                if x+1 < map.width {
                    let next = map.values[y*map.width+x+1]
                    if next.isFinite, next > 0 { differences.append(abs(value-next)) }
                }
                if y+1 < map.height {
                    let next = map.values[(y+1)*map.width+x]
                    if next.isFinite, next > 0 { differences.append(abs(value-next)) }
                }
            }
        }
        guard !differences.isEmpty else { return 0 }
        differences.sort()
        return quantile(differences, 0.5)
    }

    private static func quantile(_ sorted: [Float], _ q: Double) -> Float {
        sorted[min(sorted.count-1, max(0, Int(Double(sorted.count-1)*q)))]
    }
}

/// 只测量“目标虚化区域的像素确实变了”，不把这个指标称为画质验收。
/// 均匀白墙等低纹理背景可以正确模糊但差异很小，会显示 weakEffect 而非假成功。
struct EffectMeasurement: Sendable {
    let eligiblePixelCount: Int
    let meanAbsoluteChange: Double
    let changedFraction: Double
    var hasVisibleChange: Bool {
        eligiblePixelCount >= 8 && meanAbsoluteChange > 0.5/255 && changedFraction > 0.02
    }

    init(originalRGBA: [UInt8], renderedRGBA: [UInt8], mask: [UInt8]) throws {
        guard !mask.isEmpty, mask.count <= Int.max/4,
              originalRGBA.count == mask.count*4, renderedRGBA.count == originalRGBA.count else {
            throw DepthAnalysisError.invalidBuffer
        }
        var count = 0, changed = 0
        var total = 0.0
        for i in mask.indices where mask[i] >= 26 {
            let p = i*4
            let delta = (abs(Int(originalRGBA[p])-Int(renderedRGBA[p]))
                         + abs(Int(originalRGBA[p+1])-Int(renderedRGBA[p+1]))
                         + abs(Int(originalRGBA[p+2])-Int(renderedRGBA[p+2])))
            count += 1
            total += Double(delta) / (3*255)
            if delta >= 6 { changed += 1 }
        }
        eligiblePixelCount = count
        meanAbsoluteChange = count > 0 ? total/Double(count) : 0
        changedFraction = count > 0 ? Double(changed)/Double(count) : 0
    }
}
