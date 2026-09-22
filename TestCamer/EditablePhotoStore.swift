import Foundation
import CryptoKit

enum EditablePhotoStoreError: Error, LocalizedError {
    case invalidDocument
    case immutableOriginal
    case notFound
    case damaged(String)
    case cleanupFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument: return "照片的光圈、焦点、日期或图像数据无效，未保存这次修改。"
        case .immutableOriginal: return "原始照片、深度和初始效果不能被覆盖，之前保存的版本未改变。"
        case .notFound: return "找不到这张本机可编辑照片，可能已被删除。"
        case .damaged(let reason): return "这张可编辑照片的数据损坏或版本不受支持：\(reason)"
        case .cleanupFailed(let cause, let cleanup):
            return "保存失败：\(cause)。临时文件清理也失败：\(cleanup)"
        }
    }
}

actor EditablePhotoStore {
    /// 多个 Store 实例可共用目录；正在写入的首次事务不能被另一个实例回收。
    private final class ActiveInitialWrites: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func insert(_ url: URL) { lock.lock(); defer { lock.unlock() }; paths.insert(url.standardizedFileURL.resolvingSymlinksInPath().path) }
        func remove(_ url: URL) { lock.lock(); defer { lock.unlock() }; paths.remove(url.standardizedFileURL.resolvingSymlinksInPath().path) }
        func contains(_ url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return paths.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }
    private static let activeInitialWrites = ActiveInitialWrites()
    private static let initialWriteGracePeriod: TimeInterval = 24 * 60 * 60

    private struct Pointer: Codable {
        let schemaVersion: Int
        let id: UUID
        let revision: UUID
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let id: UUID
        let createdAt: Date
        let updatedAt: Date
        let initialRecipe: PhotoEditRecipe
        let recipe: PhotoEditRecipe
        let sourceSHA256: String
        let previewSHA256: String
        let depthSHA256: String?
        let renderingInfo: PhotoRenderingInfo?
    }

    private let rootDirectory: URL
    private let files = FileManager.default

    init(rootDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.rootDirectory = rootDirectory ?? support.appendingPathComponent("TestCamer/EditablePhotos", isDirectory: true)
    }

    /// 唯一提交点为 current.json 的原子替换。原图和深度永不改写；旧版本在下一次保存前清理。
    /// 中途退出最多留下未引用的版本，不会让参数和预览分别来自两次编辑。
    func save(_ document: EditablePhotoDocument) throws {
        guard Self.isValid(document) else { throw EditablePhotoStoreError.invalidDocument }
        if let depth = document.depthData {
            do { _ = try PhotoDepthData.decode(depth) }
            catch { throw EditablePhotoStoreError.invalidDocument }
        }
        try files.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let destination = packageURL(document.id)
        if files.fileExists(atPath: destination.path) {
            let previous = try load(id: document.id)
            guard previous.sourceData == document.sourceData,
                  previous.depthData == document.depthData,
                  previous.initialRecipe == document.initialRecipe,
                  previous.createdAt == document.createdAt else { throw EditablePhotoStoreError.immutableOriginal }
            let active = try readPointer(at: destination, id: document.id)
            try removeUnusedRevisions(in: destination, keeping: active.revision)
            try writeRevision(document, to: destination)
        } else {
            // 首次创建整份文档也先完成后再 rename，列表不会看到半份照片。
            let staging = rootDirectory.appendingPathComponent(".\(document.id.uuidString)-\(UUID().uuidString).staging", isDirectory: true)
            Self.activeInitialWrites.insert(staging)
            defer { Self.activeInitialWrites.remove(staging) }
            do {
                try files.createDirectory(at: staging, withIntermediateDirectories: false)
                try document.sourceData.write(to: staging.appendingPathComponent("source.bin"), options: .atomic)
                try document.depthData?.write(to: staging.appendingPathComponent("depth.bin"), options: .atomic)
                try writeRevision(document, to: staging)
                try files.moveItem(at: staging, to: destination)
            } catch { throw removeIncompleteWrite(at: staging, cause: error) }
        }
    }

    func load(id: UUID) throws -> EditablePhotoDocument {
        let package = packageURL(id)
        guard files.fileExists(atPath: package.path) else { throw EditablePhotoStoreError.notFound }
        do {
            let (manifest, previewURL) = try readManifest(at: package, id: id)
            let source = try Data(contentsOf: package.appendingPathComponent("source.bin"))
            let preview = try Data(contentsOf: previewURL)
            guard Self.digest(source) == manifest.sourceSHA256,
                  Self.digest(preview) == manifest.previewSHA256 else {
                throw EditablePhotoStoreError.damaged("图像校验失败")
            }
            let depth: Data?
            if let attachment = try depthAttachment(at: package, manifest: manifest) {
                // 文件属性与读取之间仍可能有外部改写；有界读取也防止被替换成巨型文件。
                let handle = try FileHandle(forReadingFrom: attachment.url)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: attachment.byteCount + 1) ?? Data()
                guard Self.digest(bytes) == manifest.depthSHA256 else { throw EditablePhotoStoreError.damaged("深度校验失败") }
                _ = try PhotoDepthData.decode(bytes)
                depth = bytes
            } else { depth = nil }
            let document = EditablePhotoDocument(id: id, createdAt: manifest.createdAt, updatedAt: manifest.updatedAt,
                                                 sourceData: source, initialRecipe: manifest.initialRecipe,
                                                 recipe: manifest.recipe, previewData: preview, depthData: depth,
                                                 renderingInfo: manifest.renderingInfo)
            guard Self.isValid(document) else { throw EditablePhotoStoreError.invalidDocument }
            return document
        } catch { throw EditablePhotoStoreError.damaged(error.localizedDescription) }
    }

    func list() throws -> [EditablePhotoSummary] {
        guard files.fileExists(atPath: rootDirectory.path) else { return [] }
        let packages = try files.contentsOfDirectory(at: rootDirectory,
                                                     includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                                                     options: [])
        var summaries = recoverAbandonedInitialWrites(in: packages)
        for package in packages {
            guard let id = UUID(uuidString: package.lastPathComponent) else { continue }
            do {
                let (manifest, previewURL) = try readManifest(at: package, id: id)
                // 列表只检查元数据及资源存在性，避免每次滚动读取所有全尺寸原图。
                let preview = try Data(contentsOf: previewURL)
                let sourceSize = try files.attributesOfItem(atPath: package.appendingPathComponent("source.bin").path)[.size] as? NSNumber
                guard sourceSize?.int64Value ?? 0 > 0, !preview.isEmpty,
                      Self.digest(preview) == manifest.previewSHA256 else {
                    throw EditablePhotoStoreError.damaged("缺少原图或预览数据")
                }
                _ = try depthAttachment(at: package, manifest: manifest)
                summaries.append(EditablePhotoSummary(id: id, createdAt: manifest.createdAt, updatedAt: manifest.updatedAt,
                                                       previewURL: previewURL))
            } catch {
                // 明确保留出错条目，让用户仍能删除；错误通过 summary 交给 UI 展示。
                var issue = error.localizedDescription
                var createdAt = Date.distantPast, updatedAt = Date.distantPast
                do {
                    let values = try package.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    createdAt = values.creationDate ?? .distantPast
                    updatedAt = values.contentModificationDate ?? .distantPast
                } catch { issue += "；读取文件属性失败：\(error.localizedDescription)" }
                summaries.append(EditablePhotoSummary(id: id, createdAt: createdAt,
                                                       updatedAt: updatedAt,
                                                       previewURL: package.appendingPathComponent("unavailable-preview.jpg"),
                                                       loadErrorDescription: issue))
            }
        }
        return summaries.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) throws {
        // 清理失败条目用事务 UUID 标识，绝不能据其所属照片 UUID 删除有效原图。
        // 优先寻找事务条目，即使极罕见的 UUID 碰撞也只删除临时文件。
        if files.fileExists(atPath: rootDirectory.path) {
            for entry in try files.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) {
                guard Self.stagingTransactionID(entry) == id, !Self.activeInitialWrites.contains(entry) else { continue }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                try files.removeItem(at: entry)
                return
            }
        }
        let package = packageURL(id)
        guard files.fileExists(atPath: package.path) else { throw EditablePhotoStoreError.notFound }
        try files.removeItem(at: package)
    }

    /// 系统强制结束时 catch 无法运行。超过一天且不活跃的合法 staging 可在读库时回收。
    /// 宽限期也保护另一个进程刚创建的事务；本 App 的多个 Store 实例另外共享活跃登记。
    /// 失败单独出现在列表，其他有效照片仍可使用，不把清理故障伪装成成功。
    private func recoverAbandonedInitialWrites(in entries: [URL]) -> [EditablePhotoSummary] {
        var issues: [EditablePhotoSummary] = []
        let deadline = Date().addingTimeInterval(-Self.initialWriteGracePeriod)
        for entry in entries {
            guard let transactionID = Self.stagingTransactionID(entry),
                  !Self.activeInitialWrites.contains(entry) else { continue }
            var modified = Date.distantPast
            do {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let date = values.contentModificationDate, date < deadline else { continue }
                modified = date
                try files.removeItem(at: entry)
            } catch {
                issues.append(EditablePhotoSummary(id: transactionID, createdAt: modified, updatedAt: modified,
                                                   previewURL: entry.appendingPathComponent("unavailable-preview.jpg"),
                                                   loadErrorDescription: "未完成照片的临时文件清理失败：\(error.localizedDescription)。可删除此条目，仅清理临时文件。"))
            }
        }
        return issues
    }

    private static func stagingTransactionID(_ url: URL) -> UUID? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".staging"), name.count == 82 else { return nil }
        let pair = name.dropFirst().dropLast(".staging".count)
        guard pair[pair.index(pair.startIndex, offsetBy: 36)] == "-",
              let photo = UUID(uuidString: String(pair.prefix(36))),
              let transaction = UUID(uuidString: String(pair.suffix(36))),
              name == ".\(photo.uuidString)-\(transaction.uuidString).staging" else { return nil }
        return transaction
    }

    private func packageURL(_ id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func writeRevision(_ document: EditablePhotoDocument, to package: URL) throws {
        let revisionID = UUID()
        let revision = package.appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionID.uuidString, isDirectory: true)
        do {
            try files.createDirectory(at: revision, withIntermediateDirectories: true)
            try document.previewData.write(to: revision.appendingPathComponent("preview.jpg"), options: .atomic)
            let schemaVersion = document.depthData == nil ? 1 : 2
            let manifest = Manifest(schemaVersion: schemaVersion, id: document.id, createdAt: document.createdAt,
                                    updatedAt: document.updatedAt, initialRecipe: document.initialRecipe,
                                    recipe: document.recipe, sourceSHA256: Self.digest(document.sourceData),
                                    previewSHA256: Self.digest(document.previewData),
                                    depthSHA256: document.depthData.map(Self.digest),
                                    renderingInfo: document.renderingInfo)
            try JSONEncoder().encode(manifest).write(to: revision.appendingPathComponent("manifest.json"), options: .atomic)
            let pointer = Pointer(schemaVersion: schemaVersion, id: document.id, revision: revisionID)
            try JSONEncoder().encode(pointer).write(to: package.appendingPathComponent("current.json"), options: .atomic)
            // 不在提交后做可能失败的工作，避免已保存却向调用方报告失败。
        } catch { throw removeIncompleteWrite(at: revision, cause: error) }
    }

    private func readPointer(at package: URL, id: UUID) throws -> Pointer {
        let pointer = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: package.appendingPathComponent("current.json")))
        guard (1...2).contains(pointer.schemaVersion), pointer.id == id else { throw EditablePhotoStoreError.damaged("版本或照片标识不匹配") }
        return pointer
    }

    private func readManifest(at package: URL, id: UUID) throws -> (Manifest, URL) {
        let pointer = try readPointer(at: package, id: id)
        let revision = package.appendingPathComponent("revisions").appendingPathComponent(pointer.revision.uuidString)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: revision.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == pointer.schemaVersion, manifest.id == id, manifest.initialRecipe.isValid, manifest.recipe.isValid,
              manifest.createdAt.timeIntervalSince1970.isFinite, manifest.updatedAt.timeIntervalSince1970.isFinite,
              manifest.updatedAt >= manifest.createdAt else { throw EditablePhotoStoreError.damaged("编辑参数无效") }
        switch manifest.schemaVersion {
        case 1:
            guard manifest.depthSHA256 == nil else { throw EditablePhotoStoreError.damaged("旧版本包含未支持的深度附件") }
        case 2:
            guard let hash = manifest.depthSHA256, hash.count == 64,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw EditablePhotoStoreError.damaged("缺少有效的深度校验信息")
            }
        default: throw EditablePhotoStoreError.damaged("版本不受支持")
        }
        return (manifest, revision.appendingPathComponent("preview.jpg"))
    }

    /// 列表只检查附件存在及有界尺寸，打开时再校验完整内容，避免浏览图库读取所有深度。
    private func depthAttachment(at package: URL, manifest: Manifest) throws -> (url: URL, byteCount: Int)? {
        let url = package.appendingPathComponent("depth.bin")
        guard manifest.schemaVersion == 2 else {
            guard !files.fileExists(atPath: url.path) else { throw EditablePhotoStoreError.damaged("深度附件缺少校验信息") }
            return nil
        }
        let attributes = try files.attributesOfItem(atPath: url.path)
        let count = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              count >= PhotoDepthData.minimumEncodedByteCount,
              count <= PhotoDepthData.maximumEncodedByteCount else {
            throw EditablePhotoStoreError.damaged("深度附件缺失或尺寸无效")
        }
        return (url, Int(count))
    }

    private func removeUnusedRevisions(in package: URL, keeping active: UUID) throws {
        let revisions = package.appendingPathComponent("revisions", isDirectory: true)
        for revision in try files.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil)
            where revision.lastPathComponent != active.uuidString {
            try files.removeItem(at: revision)
        }
    }

    private func removeIncompleteWrite(at url: URL, cause: Error) -> Error {
        guard files.fileExists(atPath: url.path) else { return cause }
        do { try files.removeItem(at: url); return cause }
        catch { return EditablePhotoStoreError.cleanupFailed(cause.localizedDescription, error.localizedDescription) }
    }

    private static func isValid(_ document: EditablePhotoDocument) -> Bool {
        document.initialRecipe.isValid && document.recipe.isValid
            && !document.sourceData.isEmpty && !document.previewData.isEmpty
            && document.createdAt.timeIntervalSince1970.isFinite && document.updatedAt.timeIntervalSince1970.isFinite
            && document.updatedAt >= document.createdAt
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
