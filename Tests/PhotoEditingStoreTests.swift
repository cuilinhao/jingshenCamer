import Foundation

@main
struct PhotoEditingStoreTests {
    static var checks = 0
    static var failures = 0
    static let fm = FileManager.default

    static func expect(_ condition: Bool, _ name: String) {
        checks += 1
        if condition { print("PASS: \(name)") }
        else { failures += 1; print("FAIL: \(name)") }
    }

    static func rejects(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); expect(false, name) }
        catch { expect(!error.localizedDescription.isEmpty, name) }
    }

    static func temporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("testcamer-photo-store-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func document(id: UUID = UUID()) -> EditablePhotoDocument {
        let recipe = PhotoEditRecipe(aperture: 1.4, sensorFocus: .init(x: 0.27, y: 0.83))
        return EditablePhotoDocument(id: id, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                     updatedAt: Date(timeIntervalSince1970: 1_790_000_001),
                                     sourceData: Data([0, 2, 4, 255, 17]), initialRecipe: recipe,
                                     recipe: recipe, previewData: Data([9, 8, 7, 6]))
    }

    static func roundTripAndUpdate() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let original = document()
        try await EditablePhotoStore(rootDirectory: root).save(original)
        let restarted = EditablePhotoStore(rootDirectory: root)
        let loaded = try await restarted.load(id: original.id)
        expect(loaded.sourceData == original.sourceData, "restart preserves exact original bytes")
        expect(loaded.recipe == original.recipe && loaded.initialRecipe == original.initialRecipe,
               "restart preserves selected focus, aperture and reset recipe")
        expect(loaded.createdAt == original.createdAt && loaded.updatedAt == original.updatedAt,
               "restart preserves capture and update dates")
        let listing = try await restarted.list()
        expect(listing.count == 1 && listing[0].id == original.id && listing[0].loadErrorDescription == nil,
               "library exposes saved document")
        expect(try Data(contentsOf: listing[0].previewURL) == original.previewData,
               "library preview matches saved version")

        var edited = loaded
        edited.recipe = PhotoEditRecipe(aperture: 8, sensorFocus: .init(x: 0.8, y: 0.15))
        edited.previewData = Data([1, 3, 5, 7, 9])
        edited.updatedAt = Date(timeIntervalSince1970: 1_790_000_002)
        try await restarted.save(edited)
        let reopened = try await EditablePhotoStore(rootDirectory: root).load(id: original.id)
        expect(reopened.recipe == edited.recipe && reopened.previewData == edited.previewData,
               "successful edit commits matching recipe and preview")
        expect(reopened.initialRecipe == original.initialRecipe && reopened.sourceData == original.sourceData,
               "edit preserves original source and initial reset effect")
        let after = try await restarted.list()
        expect(try Data(contentsOf: after[0].previewURL) == edited.previewData,
               "library reads the newly committed preview")
        try await restarted.delete(id: original.id)
        expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty, "delete removes source and every saved revision")
        await rejects("deleted document cannot reopen") { _ = try await restarted.load(id: original.id) }
    }

    static func invalidEditsPreservePrevious() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let original = document()
        try await store.save(original)
        let badRecipes: [PhotoEditRecipe] = [
            .init(aperture: .nan, sensorFocus: nil), .init(aperture: .infinity, sensorFocus: nil),
            .init(aperture: 1.3, sensorFocus: nil), .init(aperture: 16.1, sensorFocus: nil),
            .init(aperture: 2, sensorFocus: .init(x: .nan, y: 0.2)),
            .init(aperture: 2, sensorFocus: .init(x: 0.2, y: 1.01))
        ]
        for (index, recipe) in badRecipes.enumerated() {
            expect(!recipe.isValid, "invalid recipe \(index) is not renderable")
            var invalid = original; invalid.recipe = recipe
            await rejects("invalid recipe \(index) cannot overwrite good version") { try await store.save(invalid) }
        }
        for recipe in [PhotoEditRecipe(aperture: 1.4, sensorFocus: nil), .init(aperture: 16, sensorFocus: .init(x: 0, y: 1))] {
            expect(recipe.isValid, "valid aperture and focus boundaries are accepted")
        }
        let substituted = EditablePhotoDocument(id: original.id, createdAt: original.createdAt,
                                               updatedAt: original.updatedAt, sourceData: Data([99]),
                                               initialRecipe: original.initialRecipe, recipe: original.recipe,
                                               previewData: original.previewData)
        await rejects("save cannot silently replace original source") { try await store.save(substituted) }
        let changedInitial = EditablePhotoDocument(id: original.id, createdAt: original.createdAt,
                                                 updatedAt: original.updatedAt, sourceData: original.sourceData,
                                                 initialRecipe: .init(aperture: 16, sensorFocus: nil),
                                                 recipe: original.recipe, previewData: original.previewData)
        await rejects("save cannot change initial reset effect") { try await store.save(changedInitial) }
        var emptyPreview = original; emptyPreview.previewData = Data()
        await rejects("empty preview is rejected") { try await store.save(emptyPreview) }
        let loaded = try await store.load(id: original.id)
        expect(loaded.recipe == original.recipe && loaded.previewData == original.previewData,
               "all rejected edits leave previous committed version intact")
    }

    static func corruptedPhotoDoesNotBlockLibrary() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let good = document(), bad = document()
        try await store.save(good); try await store.save(bad)
        let badPackage = root.appendingPathComponent(bad.id.uuidString)
        try Data("broken pointer".utf8).write(to: badPackage.appendingPathComponent("current.json"))
        let items = try await store.list()
        expect(items.count == 2, "one corrupt photo does not hide healthy or damaged library entries")
        expect(items.first(where: { $0.id == good.id })?.loadErrorDescription == nil,
               "healthy photo remains usable beside corrupt photo")
        expect(items.first(where: { $0.id == bad.id })?.loadErrorDescription != nil,
               "corrupt library entry carries an explicit readable error")
        await rejects("opening corrupt photo reports an error") { _ = try await store.load(id: bad.id) }
        try await store.delete(id: bad.id)
        let remaining = try await store.list()
        expect(remaining.map(\.id) == [good.id], "damaged photo can still be deleted independently")
    }

    static func failedDiskWritePreservesPrevious() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        var original = document()
        try await store.save(original)
        let package = root.appendingPathComponent(original.id.uuidString)
        let revisions = package.appendingPathComponent("revisions")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: revisions.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: revisions.path) }
        original.recipe = .init(aperture: 11, sensorFocus: nil)
        await rejects("disk failure is surfaced to caller") { try await store.save(original) }
        let saved = try await EditablePhotoStore(rootDirectory: root).load(id: original.id)
        expect(saved.recipe.aperture == 1.4, "failed disk update keeps prior committed recipe")
        expect(saved.previewData == original.previewData, "failed disk update keeps prior committed preview")
    }

    static func incompleteRevisionNeverBecomesCurrent() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        var photo = document()
        try await store.save(photo)
        let package = root.appendingPathComponent(photo.id.uuidString)
        let revisions = package.appendingPathComponent("revisions")
        let interrupted = revisions.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: interrupted, withIntermediateDirectories: false)
        try Data([77, 77]).write(to: interrupted.appendingPathComponent("preview.jpg"))
        let reopened = try await EditablePhotoStore(rootDirectory: root).load(id: photo.id)
        expect(reopened.recipe == photo.recipe && reopened.previewData == photo.previewData,
               "interrupted uncommitted revision is ignored after restart")
        photo.recipe = .init(aperture: 8, sensorFocus: nil)
        photo.previewData = Data([11, 22, 33])
        try await store.save(photo)
        expect(!fm.fileExists(atPath: interrupted.path), "next save removes abandoned revision")

        // 子目录仍可写，使预览及 manifest 成功后，只有最后的原子指针替换失败。
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package.path) }
        photo.recipe = .init(aperture: 16, sensorFocus: nil)
        photo.previewData = Data([66, 66])
        await rejects("final commit failure is surfaced after revision files were prepared") { try await store.save(photo) }
        let committed = try await EditablePhotoStore(rootDirectory: root).load(id: photo.id)
        expect(committed.recipe.aperture == 8 && committed.previewData == Data([11, 22, 33]),
               "failed pointer replacement cannot mix new preview with old recipe")
    }

    static func detectsChangedSourceAndUnknownSchema() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let sourcePhoto = document(), versionPhoto = document()
        try await store.save(sourcePhoto); try await store.save(versionPhoto)
        let sourcePackage = root.appendingPathComponent(sourcePhoto.id.uuidString)
        try Data([0, 2, 4, 255, 18]).write(to: sourcePackage.appendingPathComponent("source.bin"))
        await rejects("source corruption is detected before reopening or overwriting") {
            _ = try await store.load(id: sourcePhoto.id)
        }
        await rejects("corrupt original cannot silently be overwritten by new save") { try await store.save(sourcePhoto) }
        let pointerURL = root.appendingPathComponent(versionPhoto.id.uuidString).appendingPathComponent("current.json")
        var pointer = try JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as! [String: Any]
        pointer["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)
        await rejects("future document format is explicitly refused") { _ = try await store.load(id: versionPhoto.id) }
        let listing = try await store.list()
        expect(listing.first(where: { $0.id == versionPhoto.id })?.loadErrorDescription != nil,
               "unknown format remains visible for deletion")
    }

    static func staleInitialWriteRecovery() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let photo = document()
        try await store.save(photo)
        let committed = root.appendingPathComponent(photo.id.uuidString)
        let stale = root.appendingPathComponent(".\(photo.id.uuidString)-\(UUID().uuidString).staging")
        let recent = root.appendingPathComponent(".\(photo.id.uuidString)-\(UUID().uuidString).staging")
        let unrelated = root.appendingPathComponent(".unrelated.staging")
        let symlink = root.appendingPathComponent(".\(UUID().uuidString)-\(UUID().uuidString).staging")
        try fm.copyItem(at: committed, to: stale)
        try fm.copyItem(at: committed, to: recent)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: committed)
        let oldDate = Date(timeIntervalSinceNow: -48 * 60 * 60)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale.path)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelated.path)
        let listed = try await EditablePhotoStore(rootDirectory: root).list()
        expect(!fm.fileExists(atPath: stale.path), "restart library reclaims stale interrupted initial save")
        expect(fm.fileExists(atPath: recent.path), "recent staging survives cleanup grace period")
        expect(fm.fileExists(atPath: unrelated.path), "cleanup leaves unrelated hidden directories unchanged")
        expect((try symlink.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true,
               "cleanup never traverses a staging-shaped symlink")
        expect(listed.map(\.id) == [photo.id], "recovery preserves the valid committed photo only in library")
        let restored = try await store.load(id: photo.id)
        expect(restored.sourceData == photo.sourceData, "staging recovery leaves committed source untouched")
    }

    static func failedStagingCleanupIsVisibleAndDeletable() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let photo = document()
        try await store.save(photo)
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".\(photo.id.uuidString)-\(transactionID.uuidString).staging")
        try fm.copyItem(at: root.appendingPathComponent(photo.id.uuidString), to: staging)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60),
                              .posixPermissions: 0o555], ofItemAtPath: staging.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path) }
        let listing = try await store.list()
        expect(listing.contains(where: { $0.id == photo.id && $0.loadErrorDescription == nil }),
               "failed cleanup does not block healthy library photos")
        expect(listing.contains(where: { $0.id == transactionID && $0.loadErrorDescription != nil }),
               "failed cleanup is a visible independently identified entry")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        do { try await store.delete(id: transactionID) }
        catch { expect(false, "failed staging entry can be deleted after access is restored: \(error)") }
        expect(!fm.fileExists(atPath: staging.path), "deleting cleanup issue removes only its abandoned transaction")
        let intact = try await store.load(id: photo.id)
        expect(intact.sourceData == photo.sourceData, "deleting same-photo staging cannot delete committed original")
    }

    static func main() async {
        do {
            try await roundTripAndUpdate()
            try await invalidEditsPreservePrevious()
            try await corruptedPhotoDoesNotBlockLibrary()
            try await failedDiskWritePreservesPrevious()
            try await incompleteRevisionNeverBecomesCurrent()
            try await detectsChangedSourceAndUnknownSchema()
            try await staleInitialWriteRecovery()
            try await failedStagingCleanupIsVisibleAndDeletable()
        } catch { failures += 1; print("FAIL: unexpected error: \(error)") }
        print("Photo editing store: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
