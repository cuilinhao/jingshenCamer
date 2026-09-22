import Foundation

/// 只接收调用方明确提供的运行事件；禁止传入照片、原始深度和点按坐标。
/// 文件句柄、轮转、格式化器和错误状态都只在 queue 使用。
/// 同一个目录同时只应有一个存活的 TestLog，App 统一使用 shared。
final class TestLog: @unchecked Sendable {
    static let shared: TestLog = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return TestLog(directory: support.appendingPathComponent("TestLog", isDirectory: true))
    }()

    private let directory: URL
    private let maxFileBytes: Int
    private let maxFiles: Int
    private let sessionID = UUID().uuidString
    private let queue = DispatchQueue(label: "com.testcamer.testlog", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let formatter: ISO8601DateFormatter
    private let fileManager = FileManager.default
    private var handle: FileHandle?
    private var currentBytes = 0
    /// 曾经丢失的事件不能在目录恢复后悄悄变成“导出成功”。本实例保留首个失败。
    private var firstWriteFailure: String?

    init(directory: URL, maxFileBytes: Int = 1_048_576, maxFiles: Int = 3) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { try? handle?.close() }

    /// 不等待磁盘或控制台；同一条已格式化、已限长事件在日志队列同时 print 和写文件。
    func record(_ event: String, category: String = "app", captureID: Int64? = nil) {
        let date = Date()
        queue.async { [self] in
            do {
                let data = try entry(event, category: category, captureID: captureID, date: date)
                print(String(decoding: data.dropLast(), as: UTF8.self))
                try prepareStorage()
                if currentBytes > maxFileBytes - data.count { try rotate() }
                guard let handle else { throw LogError.storage("日志文件未打开") }
                try handle.write(contentsOf: data)
                currentBytes += data.count
            } catch { rememberWriteFailure(error) }
        }
    }

    /// 等待先前 record 完成并同步文件。错误由随后的 export 明确抛出。
    func flush() {
        onQueue {
            do { try handle?.synchronize() }
            catch { rememberWriteFailure(error) }
        }
    }

    /// 等待已有事件，按旧到新合并轮转文件，生成独立不可变分享快照。
    /// 可在后台线程调用；不会将以后的 record 写入已经交给分享页的 URL。
    func export() throws -> URL {
        try onQueue {
            if let failure = firstWriteFailure { throw LogError.writeFailure(failure) }
            do {
                try prepareStorage()
                try handle?.synchronize()
            } catch {
                rememberWriteFailure(error)
                throw LogError.writeFailure(firstWriteFailure ?? Self.errorDescription(error))
            }

            var snapshot = Data(("TestCamer TestLog snapshot\nexportedAt=\(formatter.string(from: Date())) "
                + "exportingSession=\(sessionID)\n\n").utf8)
            for index in (0..<maxFiles).reversed() {
                let file = logURL(index)
                if fileManager.fileExists(atPath: file.path) {
                    snapshot.append(try Data(contentsOf: file))
                }
            }
            let exportDirectory = directory.appendingPathComponent("exports", isDirectory: true)
            try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let result = exportDirectory.appendingPathComponent("testlog-export-\(UUID().uuidString).log")
            try snapshot.write(to: result, options: .atomic)
            pruneOldExports(in: exportDirectory, keeping: result)
            return result
        }
    }

    static func errorDescription(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) code=\(value.code): \(value.localizedDescription)"
    }

    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try work() }
        return try queue.sync(execute: work)
    }

    private func logURL(_ index: Int) -> URL { directory.appendingPathComponent("testlog-\(index).log") }

    private func prepareStorage() throws {
        guard maxFileBytes > 0, maxFiles > 0 else { throw LogError.storage("日志大小和文件数量必须大于零") }
        guard handle == nil else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = logURL(0)
        if !fileManager.fileExists(atPath: file.path),
           !fileManager.createFile(atPath: file.path, contents: nil) {
            throw LogError.storage("无法创建日志文件：\(file.lastPathComponent)")
        }
        let opened = try FileHandle(forWritingTo: file)
        do {
            let end = try opened.seekToEnd()
            guard end <= UInt64(Int.max) else { throw LogError.storage("已有日志文件过大") }
            currentBytes = Int(end)
            handle = opened
        } catch {
            try? opened.close()
            throw error
        }
    }

    private func rotate() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        let oldest = logURL(maxFiles - 1)
        if fileManager.fileExists(atPath: oldest.path) { try fileManager.removeItem(at: oldest) }
        if maxFiles > 1 {
            for index in stride(from: maxFiles - 1, through: 1, by: -1) {
                let previous = logURL(index - 1)
                if fileManager.fileExists(atPath: previous.path) {
                    try fileManager.moveItem(at: previous, to: logURL(index))
                }
            }
        }
        currentBytes = 0
        try prepareStorage()
    }

    private func entry(_ event: String, category: String, captureID: Int64?, date: Date) throws -> Data {
        let category = utf8Prefix(escaped(category), bytes: 48)
        let prefix = "\(formatter.string(from: date)) session=\(sessionID) category=\(category) "
            + "captureID=\(captureID.map(String.init) ?? "-") event="
        let event = escaped(event)
        let suffix = " [truncated]"
        guard maxFiles > 0, maxFileBytes >= prefix.utf8.count + suffix.utf8.count + 1 else {
            throw LogError.storage("日志大小上限不足以容纳事件头")
        }
        let available = maxFileBytes - prefix.utf8.count - 1
        let message = event.utf8.count <= available ? event
            : utf8Prefix(event, bytes: available - suffix.utf8.count) + suffix
        return Data((prefix + message + "\n").utf8)
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func utf8Prefix(_ value: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        var data = Data(value.utf8.prefix(bytes))
        // 截断只能发生在末尾一个 UTF-8 标量内，至多去掉三个残缺字节。
        while !data.isEmpty {
            if let result = String(data: data, encoding: .utf8) { return result }
            data.removeLast()
        }
        return ""
    }

    private func rememberWriteFailure(_ error: Error) {
        let description = Self.errorDescription(error)
        if firstWriteFailure == nil { firstWriteFailure = description }
        print("[TestLog] 日志写入失败：\(description)")
    }

    private func pruneOldExports(in exportDirectory: URL, keeping current: URL) {
        // 保留最近十份，并且绝不清理七天内生成的新快照，避免后续导出破坏分享页。
        // 短期连续导出可以超过十份；只有过期文件进入清理范围。
        do {
            let files = try fileManager.contentsOfDirectory(at: exportDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("testlog-export-") && $0.pathExtension == "log" }
            let dated = try files.map { file in
                (file, try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
            let cutoff = Date(timeIntervalSinceNow: -7 * 24 * 3600)
            for (file, date) in dated.dropFirst(10) where date < cutoff && file != current {
                try fileManager.removeItem(at: file)
            }
        } catch {
            // 清理失败不使已创建的完整快照失效，也不伪装为日志写入丢失。
            print("[TestLog] 旧导出清理失败：\(Self.errorDescription(error))")
        }
    }

    private enum LogError: Error, LocalizedError {
        case storage(String), writeFailure(String)
        var errorDescription: String? {
            switch self {
            case .storage(let reason): return reason
            case .writeFailure(let reason): return "日志写入失败，无法导出完整记录：\(reason)"
            }
        }
    }
}
