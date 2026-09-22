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

struct EditablePhotoDocument: Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let sourceData: Data
    let initialRecipe: PhotoEditRecipe
    var recipe: PhotoEditRecipe
    var previewData: Data

    init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(), sourceData: Data,
         initialRecipe: PhotoEditRecipe, recipe: PhotoEditRecipe, previewData: Data) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceData = sourceData
        self.initialRecipe = initialRecipe
        self.recipe = recipe
        self.previewData = previewData
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
