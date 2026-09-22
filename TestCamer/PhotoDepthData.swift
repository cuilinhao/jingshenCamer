import Foundation

enum PhotoDepthSource: String, Codable, Sendable {
    case native, estimated
}

enum PhotoDepthDataError: Error, LocalizedError {
    case invalidData, unsupportedVersion, insufficientDepth

    var errorDescription: String? {
        switch self {
        case .invalidData: return "保存的深度附件格式、尺寸或坐标约定无效。"
        case .unsupportedVersion: return "保存的深度附件版本不受支持。"
        case .insufficientDepth: return "有效深度不足，无法保存可编辑深度附件。"
        }
    }
}

/// 不可变的完整传感器视差快照：左上原点、未应用 EXIF，大值表示近景。
/// 原生和估计视差都保留其数值尺度；无效样本统一为 0，不把相对视差当作米数。
struct PhotoDepthData: Sendable {
    let raster: DepthRaster
    let source: PhotoDepthSource

    private static let headerByteCount = 24
    static let minimumEncodedByteCount = headerByteCount + MemoryLayout<Float>.size
    static let maximumEncodedByteCount = headerByteCount + 4096 * 4096 * MemoryLayout<Float>.size
    private static let magic: [UInt8] = [84, 67, 68, 69, 80, 84, 72, 0] // TCDEPTH\0

    init(raster: DepthRaster, source: PhotoDepthSource) throws {
        guard (1...4096).contains(raster.width), (1...4096).contains(raster.height),
              raster.values.count == raster.width * raster.height else { throw PhotoDepthDataError.invalidData }
        var validCount = 0
        let values = raster.values.map { sample -> Float in
            guard sample.isFinite, sample > 0 else { return 0 }
            validCount += 1
            return sample
        }
        guard validCount >= (values.count + 3) / 4 else { throw PhotoDepthDataError.insufficientDepth }
        self.raster = try DepthRaster(width: raster.width, height: raster.height, values: values)
        self.source = source
    }

    private init(validatedRaster: DepthRaster, source: PhotoDepthSource) {
        raster = validatedRaster
        self.source = source
    }

    /// Version 1: 8-byte magic, UInt16 version, UInt8 source, UInt8 coordinates (0),
    /// UInt32 width/height/count, followed by exactly count IEEE-754 Float32 samples.
    /// All numeric fields are little-endian. Coordinates 0 means sensor top-left, large = near.
    func encoded() throws -> Data {
        var data = Data(count: Self.headerByteCount + raster.values.count * 4)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (offset, byte) in Self.magic.enumerated() { bytes[offset] = byte }
            bytes[8] = 1
            bytes[10] = source == .native ? 0 : 1
            Self.writeWord(UInt32(raster.width), to: bytes, at: 12)
            Self.writeWord(UInt32(raster.height), to: bytes, at: 16)
            Self.writeWord(UInt32(raster.values.count), to: bytes, at: 20)
            for (index, value) in raster.values.enumerated() {
                Self.writeWord(value.bitPattern, to: bytes, at: Self.headerByteCount + index * 4)
            }
        }
        return data
    }

    static func decode(_ data: Data) throws -> PhotoDepthData {
        // Bound the byte count and all header fields before allocating a sample array.
        guard (minimumEncodedByteCount...maximumEncodedByteCount).contains(data.count) else {
            throw PhotoDepthDataError.invalidData
        }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard magic.enumerated().allSatisfy({ bytes[$0.offset] == $0.element }) else {
                throw PhotoDepthDataError.invalidData
            }
            guard bytes[8] == 1, bytes[9] == 0 else { throw PhotoDepthDataError.unsupportedVersion }
            guard bytes[10] <= 1, bytes[11] == 0 else { throw PhotoDepthDataError.invalidData }
            let width = Int(readWord(bytes, at: 12)), height = Int(readWord(bytes, at: 16))
            guard (1...4096).contains(width), (1...4096).contains(height) else { throw PhotoDepthDataError.invalidData }
            let count = width * height
            guard Int(readWord(bytes, at: 20)) == count, data.count == headerByteCount + count * 4 else {
                throw PhotoDepthDataError.invalidData
            }
            var validCount = 0
            var values = [Float](repeating: 0, count: count)
            for index in values.indices {
                let sample = Float(bitPattern: readWord(bytes, at: headerByteCount + index * 4))
                if sample.isFinite, sample > 0 { values[index] = sample; validCount += 1 }
            }
            guard validCount >= (count + 3) / 4 else { throw PhotoDepthDataError.insufficientDepth }
            return PhotoDepthData(validatedRaster: try DepthRaster(width: width, height: height, values: values),
                                  source: bytes[10] == 0 ? .native : .estimated)
        }
    }

    private static func readWord(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func writeWord(_ word: UInt32, to bytes: UnsafeMutableRawBufferPointer, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: word)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: word >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: word >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: word >> 24)
    }
}
