import Foundation

@main
struct TestLogTests {
    static var checks = 0
    static var failures = 0
    static let fm = FileManager.default

    static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if condition() { print("PASS: \(name)") }
        else { failures += 1; print("FAIL: \(name)") }
    }
    static func temporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("testcamer-testlog-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    static func eventLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.contains(" event=") }
    }
    static func session(_ line: String) -> String? {
        line.components(separatedBy: " ").first(where: { $0.hasPrefix("session=") })
    }

    static func concurrentWrites() throws {
        let dir = try temporaryDirectory(); defer { try? fm.removeItem(at: dir) }
        let log = TestLog(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<80 {
                log.record("worker-\(worker)-event-\(index)", category: "capture", captureID: Int64(worker))
            }
        }
        log.flush()
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("testlog-") && $0.pathExtension == "log" }
        let onDisk = try files.map(text).joined(separator: "\n")
        expect(eventLines(onDisk).count == 640, "flush makes all concurrent entries visible in real files")
        let lines = eventLines(try text(log.export()))
        expect(lines.count == 640, "concurrent records are exported exactly once")
        let events = Set(lines.compactMap { $0.components(separatedBy: " event=").last })
        let expected = Set((0..<8).flatMap { worker in (0..<80).map { "worker-\(worker)-event-\($0)" } })
        expect(events == expected, "concurrent writes do not merge, truncate, or lose entries")
        expect(!lines.isEmpty && Set(lines.compactMap(session)).count == 1,
               "one logger instance uses one session identifier")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        expect(!lines.isEmpty && lines.allSatisfy {
            guard let timestamp = $0.components(separatedBy: " ").first else { return false }
            return formatter.date(from: timestamp) != nil && $0.contains(" category=capture ")
                && $0.contains(" captureID=")
        }, "each event includes parseable ISO time, category, and capture ID")
    }

    static func restartPreservesHistory() throws {
        let dir = try temporaryDirectory(); defer { try? fm.removeItem(at: dir) }
        do {
            let first = TestLog(directory: dir)
            first.record("before-restart"); first.flush()
        }
        let second = TestLog(directory: dir)
        second.record("after-restart")
        let lines = eventLines(try text(second.export()))
        expect(lines.contains(where: { $0.hasSuffix("event=before-restart") })
               && lines.contains(where: { $0.hasSuffix("event=after-restart") }),
               "restart appends without erasing the previous session")
        expect(Set(lines.compactMap(session)).count == 2, "restart produces a distinguishable new session")
    }

    static func rotationAndUnicode() throws {
        let dir = try temporaryDirectory(); defer { try? fm.removeItem(at: dir) }
        let log = TestLog(directory: dir, maxFileBytes: 512, maxFiles: 3)
        for index in 0..<60 {
            log.record("rotated-\(index) " + String(repeating: "x", count: 100))
        }
        log.flush()
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("testlog-") && $0.pathExtension == "log" }
        let sizes = try files.map { try Data(contentsOf: $0).count }
        expect(files.count == 3 && sizes.allSatisfy { $0 <= 512 } && sizes.reduce(0, +) <= 1536,
               "rotation honors both per-file and aggregate byte limits")
        let snapshot = try text(log.export())
        expect(snapshot.contains("event=rotated-59 ") && !snapshot.contains("event=rotated-0 "),
               "rotation retains the newest events and discards the oldest")
        let indices = eventLines(snapshot).compactMap { line -> Int? in
            guard let tail = line.components(separatedBy: "event=rotated-").last else { return nil }
            return Int(tail.components(separatedBy: " ").first ?? "")
        }
        expect(!indices.isEmpty && indices == indices.sorted(), "export combines rotated logs in chronological order")
        log.record(String(repeating: "🙂测试", count: 1000), category: "encoding")
        let unicode = try text(log.export())
        expect(unicode.contains("truncated") && !unicode.contains("�"),
               "oversized events are bounded without splitting UTF-8 characters")
        let finalFiles = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("testlog-") && $0.pathExtension == "log" }
        let bounded = try finalFiles.allSatisfy { try Data(contentsOf: $0).count <= 512 }
        expect(bounded, "an oversized message cannot exceed the rotation size limit")
    }

    static func immutableSnapshots() throws {
        let dir = try temporaryDirectory(); defer { try? fm.removeItem(at: dir) }
        let log = TestLog(directory: dir)
        log.record("first-export")
        let first = try log.export()
        let bytes = try Data(contentsOf: first)
        log.record("second-export")
        let second = try log.export()
        expect(first != second, "each export has a separate immutable URL")
        let stillFirst = try Data(contentsOf: first)
        expect(stillFirst == bytes, "later export does not overwrite a shared snapshot")
        let secondText = try text(second)
        expect(secondText.contains("event=second-export") && !String(decoding: bytes, as: UTF8.self).contains("event=second-export"),
               "export flushes all earlier records before taking its snapshot")
        log.record("one\ntwo\rthree\tfour", category: "line\nbreak")
        let escaped = try text(log.export())
        expect(eventLines(escaped).count == 3 && escaped.contains("one\\ntwo\\rthree\\tfour"),
               "newlines and tabs cannot forge extra log entries")

        // Real aged files exercise cleanup; recently shared URLs must remain intact.
        let exportDir = second.deletingLastPathComponent()
        for index in 0..<15 {
            let old = exportDir.appendingPathComponent("testlog-export-old-\(index).log")
            try Data("old".utf8).write(to: old)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -9*24*3600)], ofItemAtPath: old.path)
        }
        _ = try log.export()
        let remaining = try fm.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
        expect(remaining.filter { $0.lastPathComponent.hasPrefix("testlog-export-old-") }.count < 15,
               "export eventually prunes obsolete snapshots")
        expect(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: second.path),
               "snapshot cleanup retains recent URLs that may still be shared")
    }

    static func failuresAreReported() throws {
        let dir = try temporaryDirectory(); defer { try? fm.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocked)
        let log = TestLog(directory: blocked)
        log.record("must-not-silently-disappear"); log.flush()
        var writeFailure: Error?
        do { _ = try log.export() } catch { writeFailure = error }
        expect(writeFailure != nil, "a failed asynchronous write makes export throw")
        try fm.removeItem(at: blocked)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        var retainedFailure = false
        do { _ = try log.export() } catch { retainedFailure = true }
        expect(retainedFailure, "repairing the directory does not silently hide already-lost records")

        let exportBlocked = dir.appendingPathComponent("export-blocked")
        let healthy = TestLog(directory: exportBlocked)
        healthy.record("stored-successfully"); healthy.flush()
        try fm.createDirectory(at: exportBlocked, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: exportBlocked.appendingPathComponent("exports"))
        var exportFailed = false
        do { _ = try healthy.export() } catch { exportFailed = true }
        expect(exportFailed, "an unwritable export location throws instead of returning a nonexistent file")
        let error = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "expected failure"])
        let description = TestLog.errorDescription(error)
        expect(description.contains("TestDomain") && description.contains("42") && description.contains("expected failure"),
               "error descriptions retain domain, code, and readable reason")
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("concurrency", concurrentWrites), ("restart", restartPreservesHistory),
            ("rotation", rotationAndUnicode), ("snapshots", immutableSnapshots),
            ("errors", failuresAreReported)
        ]
        for (name, test) in tests {
            do { try test() }
            catch { expect(false, "\(name) unexpectedly threw: \(error)") }
        }
        print("\n\(checks) TestLog checks; \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
