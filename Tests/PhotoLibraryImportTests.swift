import Foundation
import CoreImage
import ImageIO
import AVFoundation

@main
struct PhotoLibraryImportTests {
    static var checks = 0
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }

    static func run(_ name: String, _ work: () async throws -> Void) async {
        do { try await work() }
        catch { expect(false, "\(name): unexpected error: \(error)") }
    }

    static func main() async {
        let context = CIContext(options: [.cacheIntermediates: false])
        await run("native disparity") { try await nativeImport(context: context, useMetricDepth: false) }
        await run("native depth") { try await nativeImport(context: context, useMetricDepth: true) }
        await run("RGB orientations") { try await rgbImports(context: context) }
        await run("invalid input") { try await invalidInputs(context: context) }
        await run("estimation failure") { try await estimationFailure(context: context) }
        await run("invalid native fallback") { try await invalidNativeFallback(context: context) }
        await run("cancelled import") { try await cancelledImport(context: context) }
        if CommandLine.arguments.contains("--model-smoke") {
            await run("bundled model") { try await bundledModel(context: context) }
        }
        print("Photo library import: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }

    // Losing the auxiliary container, forcing estimation, or using a rendered
    // JPEG as the editable source must break these actual Apple render checks.
    static func nativeImport(context: CIContext, useMetricDepth: Bool) async throws {
        let exif: UInt32 = useMetricDepth ? 6 : 1
        let disparity = try AppleDepthTestFixture.photo(context: context, orientation: exif)
        let data = try useMetricDepth ? metricDepthPhoto(disparity, orientation: exif) : disparity
        let importer = PhotoLibraryImporter(processor: DepthPhotoProcessor(depthEstimator: { _ in
            throw FixtureError.estimationUnavailable
        }))
        let imported = try await importer.prepare(data: data)
        let document = imported.document
        expect(document.sourceData == data, "native: original image and auxiliary bytes remain exact")
        expect(document.depthData == nil, "native: Apple editing keeps its original auxiliary container")
        expect(document.renderingInfo?.appleFallbackReason == nil, "native: Apple path does not fall back")
        expect(document.initialRecipe.isValid && document.recipe == document.initialRecipe,
               "native: import retains the actual initial focus and aperture")
        expect(document.recipe.aperture == 1.4, "native: initial aperture matches the camera default")
        expect(!imported.originalPreviewData.isEmpty && !document.previewData.isEmpty,
               "native: comparison and edited previews are available")
        try expectDimensions(imported.originalPreviewData, exif: exif, "native original")
        try expectDimensions(document.previewData, exif: exif, "native edited")
        try await persistAndReopen(imported, exif: exif)
    }

    // Inference receives upright pixels, but persisted depth must return to raw
    // sensor coordinates. Omitting that transform breaks both mirrors and turns.
    static func rgbImports(context: CIContext) async throws {
        let raw = try fixtureDepth()
        for exif: UInt32 in 1...8 {
            let source = try jpeg(context: context, orientation: exif)
            let upright = raw.oriented(exif: exif)
            let importer = PhotoLibraryImporter(processor: DepthPhotoProcessor(depthEstimator: { image in
                let expectedWidth: CGFloat = exif < 5 ? 768 : 512
                let expectedHeight: CGFloat = exif < 5 ? 512 : 768
                guard image.extent == CGRect(x: 0, y: 0, width: expectedWidth, height: expectedHeight) else {
                    throw FixtureError.orientation
                }
                return upright
            }))
            let imported = try await importer.prepare(data: source)
            expect(imported.document.sourceData == source, "RGB EXIF \(exif): original JPEG is not reencoded")
            expect(imported.document.recipe.isValid && imported.document.initialRecipe == imported.document.recipe,
                   "RGB EXIF \(exif): valid initial edit recipe")
            guard let bytes = imported.document.depthData else {
                expect(false, "RGB EXIF \(exif): estimated depth is retained for later editing"); continue
            }
            let depth = try PhotoDepthData.decode(bytes)
            expect(depth.source == .estimated, "RGB EXIF \(exif): estimation is not labelled native")
            expect(depth.raster.width == 96 && depth.raster.height == 64 && depth.raster.values == raw.values,
                   "RGB EXIF \(exif): cached samples preserve exact sensor geometry and order")
            try expectDimensions(imported.originalPreviewData, exif: exif, "RGB original")
            try expectDimensions(imported.document.previewData, exif: exif, "RGB edited")
            if exif == 6 { try await persistAndReopen(imported, exif: exif) }
        }
    }

    static func invalidInputs(context: CIContext) async throws {
        let valid = try jpeg(context: context)
        let importer = PhotoLibraryImporter()
        for data in [Data(), Data([0, 1, 2, 3]), Data("not a photo".utf8), Data(valid.prefix(128))] {
            do {
                _ = try await importer.prepare(data: data)
                expect(false, "invalid input cannot create an editable document")
            } catch let error as PhotoLibraryImportError {
                expect(error == .invalidImage, "invalid input has an image-specific import error")
                expect(error.localizedDescription.contains("导入"), "invalid input reports Chinese import context")
            }
        }
    }

    // The processor intentionally returns an ordinary photo after failed
    // inference; the importer must reject that result instead of saving it.
    static func estimationFailure(context: CIContext) async throws {
        let importer = PhotoLibraryImporter(processor: DepthPhotoProcessor(depthEstimator: { _ in
            throw FixtureError.estimationUnavailable
        }))
        do {
            _ = try await importer.prepare(data: jpeg(context: context))
            expect(false, "failed estimation cannot create an uneditable library entry")
        } catch let error as PhotoLibraryImportError {
            expect(error == .processingFailed, "failed estimation reports an import processing failure")
            expect(error.localizedDescription.contains("导入"), "failed estimation reports Chinese import context")
        }
    }

    static func invalidNativeFallback(context: CIContext) async throws {
        let source = try AppleDepthTestFixture.photo(context: context, disparityValue: { _, _ in 0 })
        let depth = try fixtureDepth()
        let importer = PhotoLibraryImporter(processor: DepthPhotoProcessor(depthEstimator: { _ in depth }))
        let imported = try await importer.prepare(data: source)
        guard let bytes = imported.document.depthData else {
            expect(false, "unusable auxiliary depth falls back to editable estimated depth"); return
        }
        let stored = try PhotoDepthData.decode(bytes)
        expect(stored.source == .estimated,
               "unusable native auxiliary depth cannot suppress RGB fallback")
        expect(imported.document.sourceData == source, "fallback still preserves the original source bytes")
    }

    static func cancelledImport(context: CIContext) async throws {
        let data = try jpeg(context: context)
        let depth = try fixtureDepth()
        let importer = PhotoLibraryImporter(processor: DepthPhotoProcessor(depthEstimator: { _ in depth }))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.prepare(data: data)
        }
        do {
            _ = try await task.value
            expect(false, "cancelled import cannot return a document to be saved")
        } catch is CancellationError { expect(true, "cancelled import propagates cancellation") }
    }

    static func bundledModel(context: CIContext) async throws {
        let imported = try await PhotoLibraryImporter().prepare(data: jpeg(context: context))
        guard let bytes = imported.document.depthData else {
            expect(false, "bundled offline model produces an editable depth attachment"); return
        }
        let stored = try PhotoDepthData.decode(bytes)
        expect(stored.source == .estimated,
               "real bundled inference is preserved as estimated depth")
        try await persistAndReopen(imported, exif: 1)
    }

    static func persistAndReopen(_ imported: ImportedEditablePhoto, exif: UInt32) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = imported.document
        try await EditablePhotoStore(rootDirectory: root).save(original)
        var reopened = try await EditablePhotoStore(rootDirectory: root).load(id: original.id)
        expect(reopened.sourceData == original.sourceData && reopened.depthData == original.depthData,
               "restart retains exact source and depth attachment")
        expect(reopened.initialRecipe == original.initialRecipe && reopened.renderingInfo == original.renderingInfo,
               "restart retains the initial effect and rendering provenance")
        let result = try await PhotoEditingRenderer().render(sourceData: reopened.sourceData,
            recipe: reopened.recipe, depthData: reopened.depthData)
        try expectDimensions(result.jpegData, exif: exif, "reopened render")
        reopened.recipe = PhotoEditRecipe(aperture: 8, sensorFocus: .init(x: 0.25, y: 0.25))
        let edited = try await PhotoEditingRenderer().render(sourceData: reopened.sourceData,
            recipe: reopened.recipe, depthData: reopened.depthData)
        expect(edited.jpegData != result.jpegData, "reopened import supports a visible focus/aperture edit")
        reopened.previewData = edited.jpegData
        try await EditablePhotoStore(rootDirectory: root).save(reopened)
        let saved = try await EditablePhotoStore(rootDirectory: root).load(id: original.id)
        expect(saved.recipe == reopened.recipe && saved.previewData == edited.jpegData,
               "edits to an imported document survive another restart")
    }

    static func expectDimensions(_ data: Data, exif: UInt32, _ label: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw FixtureError.encoding
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        expect(width == (exif < 5 ? 768 : 512) && height == (exif < 5 ? 512 : 768),
               "\(label) EXIF \(exif): preview has upright dimensions")
        expect((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1 == 1,
               "\(label) EXIF \(exif): exported preview orientation is upright")
    }

    static func fixtureDepth() throws -> DepthRaster {
        try DepthRaster(width: 96, height: 64, values: (0..<96*64).map { index in
            let x = index % 96, y = index / 96
            return [Float(0.9), 0.65, 0.4, 0.1][(y < 32 ? 0 : 2) + (x < 48 ? 0 : 1)]
        })
    }

    static func jpeg(context: CIContext, orientation: UInt32 = 1) throws -> Data {
        let heic = try AppleDepthTestFixture.photo(context: context, includeDepth: false)
        guard let source = CGImageSourceCreateWithData(heic as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FixtureError.encoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw FixtureError.encoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encoding }
        return data as Data
    }

    static func metricDepthPhoto(_ disparityPhoto: Data, orientation: UInt32) throws -> Data {
        guard let source = CGImageSourceCreateWithData(disparityPhoto as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
                as? [AnyHashable: Any] else { throw FixtureError.encoding }
        let depth = try AVDepthData(fromDictionaryRepresentation: auxiliary)
            .converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        var type: NSString?
        guard let serial = depth.dictionaryRepresentation(forAuxiliaryDataType: &type) else {
            throw FixtureError.encoding
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else {
            throw FixtureError.encoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDepth, serial as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encoding }
        return data as Data
    }

    enum FixtureError: Error { case encoding, estimationUnavailable, orientation }
}
