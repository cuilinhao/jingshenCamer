import Foundation

struct PhotoEditRecipe: Codable, Equatable, Sendable {
    let aperture: Float
    /// 左上原点、未应用 EXIF 的完整传感器图像归一化坐标。
    let sensorFocus: NormalizedImagePoint?

    init(aperture: Float, sensorFocus: NormalizedImagePoint?) {
        self.aperture = aperture
        self.sensorFocus = sensorFocus
    }

    var isValid: Bool {
        aperture.isFinite && (1.4...16).contains(aperture) && (sensorFocus?.isValid ?? true)
    }
}

/// 随当前预览保存的处理信息；旧照片缺少此信息时不推测回退原因。
struct PhotoRenderingInfo: Codable, Equatable, Sendable {
    let appleFallbackReason: String?
    var usedAppleMetadataCompatibility: Bool
}

struct EditablePhotoDocument: Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let sourceData: Data
    let initialRecipe: PhotoEditRecipe
    var recipe: PhotoEditRecipe
    var previewData: Data
    /// 与原图一起首次保存的传感器坐标视差附件，后续编辑不可替换。
    let depthData: Data?
    var renderingInfo: PhotoRenderingInfo?

    init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(), sourceData: Data,
         initialRecipe: PhotoEditRecipe, recipe: PhotoEditRecipe, previewData: Data, depthData: Data? = nil,
         renderingInfo: PhotoRenderingInfo? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceData = sourceData
        self.initialRecipe = initialRecipe
        self.recipe = recipe
        self.previewData = previewData
        self.depthData = depthData
        self.renderingInfo = renderingInfo
    }
}

struct EditablePhotoSummary: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let previewURL: URL
    /// 列表保留损坏条目供用户删除，打开时仍明确报告失败。
    var loadErrorDescription: String? = nil
}
