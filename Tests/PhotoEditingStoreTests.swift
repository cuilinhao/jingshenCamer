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

    static func withDepth(_ photo: EditablePhotoDocument, _ depth: Data?) -> EditablePhotoDocument {
        EditablePhotoDocument(id: photo.id, createdAt: photo.createdAt, updatedAt: photo.updatedAt,
                              sourceData: photo.sourceData, initialRecipe: photo.initialRecipe,
                              recipe: photo.recipe, previewData: photo.previewData, depthData: depth)
    }

    static func depthBytes(source: PhotoDepthSource = .estimated) throws -> Data {
        try PhotoDepthData(raster: DepthRaster(width: 3, height: 2, values: [1, 2, 3, 4, 5, 6]),
                           source: source).encoded()
    }

    static func manifestURL(in package: URL) throws -> URL {
        let pointer = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("current.json"))) as! [String: Any]
        return package.appendingPathComponent("revisions").appendingPathComponent(pointer["revision"] as! String)
            .appendingPathComponent("manifest.json")
    }

    static func depthSnapshotRoundTripAndValidation() async throws {
        for source in [PhotoDepthSource.native, .estimated] {
            let input: [Float] = [1.125, .nan, .infinity, -1, 0, 5.25]
            let snapshot = try PhotoDepthData(raster: DepthRaster(width: 3, height: 2, values: input), source: source)
            expect(snapshot.raster.values == [1.125, 0, 0, 0, 0, 5.25],
                   "depth initializer normalizes invalid and nonpositive samples for \(source)")
            let restored = try PhotoDepthData.decode(snapshot.encoded())
            expect(restored.source == source && restored.raster.width == 3 && restored.raster.height == 2,
                   "depth round trip preserves provenance and non-square sensor geometry for \(source)")
            expect(restored.raster.values == [1.125, 0, 0, 0, 0, 5.25],
                   "depth round trip preserves top-left row order and floating point disparities for \(source)")
        }
        let extreme: [Float] = [.leastNonzeroMagnitude, .greatestFiniteMagnitude, 3.1415927, 0.125]
        let exact = try PhotoDepthData.decode(PhotoDepthData(raster: DepthRaster(width: 2, height: 2, values: extreme), source: .native).encoded())
        expect(exact.raster.values.map(\.bitPattern) == extreme.map(\.bitPattern), "depth payload preserves every finite positive Float32 bit pattern")
        let boundary = try PhotoDepthData(raster: DepthRaster(width: 2, height: 2, values: [2, .nan, -2, 0]), source: .estimated)
        expect(boundary.raster.values == [2, 0, 0, 0], "exactly 25 percent valid depth remains cacheable")
        let flat = try PhotoDepthData(raster: DepthRaster(width: 3, height: 2, values: Array(repeating: 2, count: 6)), source: .estimated)
        expect(try PhotoDepthData.decode(flat.encoded()).raster.values == Array(repeating: 2, count: 6),
               "flat scenes retain their depth attachment for later editing")
        let single = try PhotoDepthData(raster: DepthRaster(width: 1, height: 1, values: [2]), source: .native)
        expect(try PhotoDepthData.decode(single.encoded()).raster.values == [2], "one-pixel positive depth satisfies the documented dimensions")
        await rejects("less than 25 percent depth coverage is rejected") {
            _ = try PhotoDepthData(raster: DepthRaster(width: 3, height: 2, values: [2, 0, 0, 0, 0, 0]), source: .estimated)
        }
        await rejects("all-invalid depth is rejected") {
            _ = try PhotoDepthData(raster: DepthRaster(width: 2, height: 2, values: [.nan, -.infinity, -1, 0]), source: .native)
        }
        await rejects("unrecognized depth bytes are rejected") { _ = try PhotoDepthData.decode(Data([1, 2, 3])) }
        let valid = try depthBytes()
        await rejects("truncated float payload is rejected") { _ = try PhotoDepthData.decode(valid.dropLast()) }
        await rejects("trailing depth bytes are rejected") { _ = try PhotoDepthData.decode(valid + Data([0])) }

        // Version 1 wire fixture: TCDEPTH\0, UInt16 version, source/coordinate bytes,
        // little-endian UInt32 width, height and sample count, then Float32 values.
        let fixture = Data([84, 67, 68, 69, 80, 84, 72, 0, 1, 0, 0, 0,
                            2, 0, 0, 0, 2, 0, 0, 0, 4, 0, 0, 0,
                            0, 0, 0, 64, 0, 0, 128, 63, 0, 0, 128, 64, 0, 0, 64, 64])
        let fixtureDepth = try PhotoDepthData.decode(fixture)
        expect(fixtureDepth.source == .native && fixtureDepth.raster.values == [2, 1, 4, 3],
               "independent version 1 fixture decodes little-endian floats")
        for (offset, bytes, name) in [
            (8, [UInt8(2), 0], "future depth version"),
            (10, [UInt8(255)], "unknown depth provenance"),
            (11, [UInt8(1)], "unsupported depth coordinate convention"),
            (12, [UInt8(0), 0, 0, 0], "zero depth width"),
            (12, [UInt8(1), 16, 0, 0], "oversize depth width"),
            (16, [UInt8(255), 255, 255, 255], "overflowing depth height"),
            (20, [UInt8(255), 255, 255, 255], "overflowing sample count")
        ] {
            var corrupted = fixture
            corrupted.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            await rejects("\(name) is rejected before allocating samples") { _ = try PhotoDepthData.decode(corrupted) }
        }
        var invalidFloats = fixture
        invalidFloats.replaceSubrange(28..<40, with: [UInt8](repeating: 255, count: 12))
        expect(try PhotoDepthData.decode(invalidFloats).raster.values == [2, 0, 0, 0],
               "decoder normalizes nonfinite floats while enforcing coverage")
    }

    static func depthAttachmentPersistenceAndImmutability() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let original = withDepth(document(), try depthBytes())
        try await store.save(original)
        let package = root.appendingPathComponent(original.id.uuidString)
        let depthURL = package.appendingPathComponent("depth.bin")
        let written = try Data(contentsOf: depthURL)
        let fileDate = try depthURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        expect(written == original.depthData, "initial transaction writes exact immutable depth sidecar")
        var loaded = try await EditablePhotoStore(rootDirectory: root).load(id: original.id)
        expect(loaded.depthData == original.depthData, "restart restores exact depth attachment")
        loaded.recipe = .init(aperture: 8, sensorFocus: .init(x: 0.2, y: 0.1))
        loaded.updatedAt = Date(timeIntervalSince1970: 1_790_000_002)
        loaded.previewData = Data([1, 2, 3])
        try await store.save(loaded)
        expect(try Data(contentsOf: depthURL) == written, "editing preserves depth bytes")
        expect(try depthURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == fileDate,
               "editing never rewrites the immutable depth sidecar")
        let reopened = try await store.load(id: original.id)
        expect(reopened.depthData == original.depthData && reopened.recipe == loaded.recipe && reopened.previewData == loaded.previewData,
               "committed edit reopens with its original depth and matching recipe/preview")
        let replaced = withDepth(loaded, try depthBytes(source: .native))
        await rejects("save refuses replacement of depth provenance or pixels") { try await store.save(replaced) }
        await rejects("save refuses removal of original depth") { try await store.save(withDepth(loaded, nil)) }
        let invalid = withDepth(document(), Data([0, 1, 2]))
        await rejects("invalid depth is rejected before creating a package") { try await store.save(invalid) }
        expect(!fm.fileExists(atPath: root.appendingPathComponent(invalid.id.uuidString).path),
               "rejected initial depth leaves no incomplete document")
        let legacy = document()
        try await store.save(legacy)
        await rejects("depth cannot be attached later to an immutable legacy original") {
            try await store.save(withDepth(legacy, original.depthData))
        }
    }

    static func damagedDepthAttachmentsAreReported() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let missing = withDepth(document(), try depthBytes())
        let tampered = withDepth(document(), try depthBytes())
        let noHash = withDepth(document(), try depthBytes())
        for photo in [missing, tampered, noHash] { try await store.save(photo) }
        try fm.removeItem(at: root.appendingPathComponent(missing.id.uuidString).appendingPathComponent("depth.bin"))
        await rejects("missing depth cannot reopen") { _ = try await store.load(id: missing.id) }
        await rejects("save cannot silently repair a missing original depth") { try await store.save(missing) }
        let listing = try await store.list()
        expect(listing.first(where: { $0.id == missing.id })?.loadErrorDescription != nil,
               "library surfaces a missing depth sidecar without hiding the entry")
        let tamperedURL = root.appendingPathComponent(tampered.id.uuidString).appendingPathComponent("depth.bin")
        try depthBytes(source: .native).write(to: tamperedURL)
        await rejects("valid but substituted depth fails its manifest checksum") { _ = try await store.load(id: tampered.id) }
        await rejects("save cannot overwrite a checksum failure") { try await store.save(tampered) }
        let manifest = try manifestURL(in: root.appendingPathComponent(noHash.id.uuidString))
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        expect(metadata["schemaVersion"] as? Int == 2 && metadata["depthSHA256"] as? String != nil,
               "depth documents record schema 2 and an explicit attachment checksum")
        metadata.removeValue(forKey: "depthSHA256")
        try JSONSerialization.data(withJSONObject: metadata).write(to: manifest)
        await rejects("schema 2 cannot omit the immutable depth checksum") { _ = try await store.load(id: noHash.id) }
        let damaged = try await store.list()
        expect(damaged.first(where: { $0.id == noHash.id })?.loadErrorDescription != nil,
               "library surfaces missing attachment metadata")
    }

    static func legacySchemaRemainsReadable() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        let photo = document()
        try await store.save(photo)
        let package = root.appendingPathComponent(photo.id.uuidString)
        let manifest = try manifestURL(in: package)
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        metadata["schemaVersion"] = 1
        metadata.removeValue(forKey: "depthSHA256")
        try JSONSerialization.data(withJSONObject: metadata).write(to: manifest)
        let pointerURL = package.appendingPathComponent("current.json")
        var pointer = try JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as! [String: Any]
        pointer["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)
        var restored = try await EditablePhotoStore(rootDirectory: root).load(id: photo.id)
        expect(restored.depthData == nil && restored.sourceData == photo.sourceData && restored.recipe == photo.recipe,
               "schema 1 manifests without attachment fields retain the legacy editing path")
        restored.recipe = .init(aperture: 11, sensorFocus: nil)
        try await store.save(restored)
        let edited = try await store.load(id: restored.id)
        expect(edited.depthData == nil && edited.recipe.aperture == 11, "legacy documents remain editable without creating depth")
    }

    static func renderingInfoSurvivesRestartAndEdit() async throws {
        let root = try temporaryDirectory(); defer { try? fm.removeItem(at: root) }
        let store = EditablePhotoStore(rootDirectory: root)
        for (depth, info) in [(try depthBytes(), ["appleFallbackReason": "native depth unavailable", "usedAppleMetadataCompatibility": false] as [String: Any]),
                              (nil, ["usedAppleMetadataCompatibility": true])] as [(Data?, [String: Any])] {
            let photo = withDepth(document(), depth)
            try await store.save(photo)
            let package = root.appendingPathComponent(photo.id.uuidString)
            let manifest = try manifestURL(in: package)
            var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            metadata["renderingInfo"] = info
            try JSONSerialization.data(withJSONObject: metadata).write(to: manifest)
            var reopened = try await EditablePhotoStore(rootDirectory: root).load(id: photo.id)
            reopened.recipe = .init(aperture: 8, sensorFocus: photo.recipe.sensorFocus)
            reopened.previewData = Data([1, 5, 9])
            try await store.save(reopened)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL(in: package))) as! [String: Any]
            expect((saved["renderingInfo"] as? NSDictionary) == NSDictionary(dictionary: info),
                   "Restart and edit preserve the preview's fallback or Apple compatibility provenance")
            reopened.renderingInfo?.usedAppleMetadataCompatibility.toggle()
            reopened.previewData = Data([2, 6, 10])
            try await store.save(reopened)
            let updated = try await EditablePhotoStore(rootDirectory: root).load(id: photo.id)
            expect(updated.renderingInfo == reopened.renderingInfo && updated.previewData == reopened.previewData,
                   "Updated compatibility provenance commits atomically with its corresponding preview")
        }
        let legacy = document()
        try await store.save(legacy)
        let loadedLegacy = try await store.load(id: legacy.id)
        expect(loadedLegacy.renderingInfo == nil, "Old photos without provenance remain readable without inventing a fallback")
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
            try await depthSnapshotRoundTripAndValidation()
            try await depthAttachmentPersistenceAndImmutability()
            try await damagedDepthAttachmentsAreReported()
            try await legacySchemaRemainsReadable()
            try await renderingInfoSurvivesRestartAndEdit()
        } catch { failures += 1; print("FAIL: unexpected error: \(error)") }
        print("Photo editing store: \(checks) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
