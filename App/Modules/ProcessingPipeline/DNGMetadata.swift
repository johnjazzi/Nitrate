import Foundation

/// The DNG tags the still pipeline reasons about, read straight from the file's
/// TIFF structure.
///
/// `CIRAWFilter` will develop any raw colour filter array, but it does not
/// report the sensor's own numbers, and two of them decide how a still enters
/// the film pipeline:
///
///  * `BaselineExposure` is how far the capture was lifted relative to a neutral
///    exposure. The still path keeps it (measured +2.99 EV on an iPhone ProRAW),
///    which is right for brightness parity with the matching Log 2 take — but it
///    also lifts the light that halation measures, so the halation knees have to
///    be scaled by the same factor or every lit surface reads as superwhite.
///  * `WhiteLevel`/`BlackLevel` are the sensor's saturation and pedestal. They
///    let a caller check that a file's pixel range is what the pipeline assumes
///    instead of trusting an extension.
///
/// Deliberately not a general TIFF reader: it walks IFD0 and its SubIFDs (where
/// DNG requirements and raw dimensions live) and reads a fixed tag list. A file
/// that is not TIFF, or that fails any bounds check, reports `nil` rather than
/// partial data.
struct DNGMetadata: Equatable, Sendable {
    /// Sensor saturation, in raw sample counts.
    var whiteLevel: Double?
    /// Pedestal, in raw sample counts. Per-plane when the file gives four.
    var blackLevel: [Double]
    /// Capture lift in stops, as authored by the camera.
    var baselineExposure: Double?
    /// Bits per sample of the raw raster, when declared.
    var bitsPerSample: Int?
    /// Tag 50706, "DNGVersion" — four bytes of major.minor.patch.build.
    var dngVersion: String?
    /// Make and model, for reporting only. Never used to branch behaviour: a
    /// per-manufacturer table is exactly the rabbit hole this avoids.
    var make: String?
    var model: String?
    var uniqueCameraModel: String?

    var isDNG: Bool { dngVersion != nil }

    /// Sensor saturation after the pedestal is removed, when both are known.
    var usableWhiteLevel: Double? {
        guard let whiteLevel else { return nil }
        let pedestal = blackLevel.max() ?? 0
        let span = whiteLevel - pedestal
        return span > 0 ? span : nil
    }

    // MARK: - Tags

    private enum Tag: UInt16 {
        case make = 271
        case model = 272
        case subIFDs = 330
        case dngVersion = 50706
        case uniqueCameraModel = 50708
        case bitsPerSample = 258
        case blackLevel = 50714
        case whiteLevel = 50717
        case baselineExposure = 50730
    }

    private enum FieldType: UInt16 {
        case byte = 1, ascii = 2, short = 3, long = 4, rational = 5
        case sbyte = 6, undefined = 7, sshort = 8, slong = 9, srational = 10
        case float = 11, double = 12
        /// Bytes per element. A type this reader does not interpret still has to
        /// have its size known, or the entry cannot be skipped safely.
        var size: Int {
            switch self {
            case .byte, .ascii, .sbyte, .undefined: 1
            case .short, .sshort: 2
            case .long, .slong, .float: 4
            case .rational, .srational, .double: 8
            }
        }
    }

    private struct Value {
        var type: FieldType
        var count: Int
        /// Big-endian payload of the entry, in file byte order.
        var bytes: Data
    }

    // MARK: - Parsing

    static func read(_ url: URL) -> DNGMetadata? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> DNGMetadata? {
        guard data.count >= 8 else { return nil }
        let little: Bool
        if data[0] == 0x49, data[1] == 0x49 { little = true }
        else if data[0] == 0x4D, data[1] == 0x4D { little = false }
        else { return nil }
        guard readUInt16(data, 2, little: little) == 42,
              let first = readUInt32(data, 4, little: little) else { return nil }

        var entries: [Tag: Value] = [:]
        var subIFDOffsets: [Int] = []
        // IFD0 first, then the SubIFDs it points at (depth-limited: DNG puts raw
        // data in one level of SubIFDs, and a malformed chain must not recurse).
        var pending: [Int] = [Int(first)]
        var visited: Set<Int> = []
        while let offset = pending.popLast() {
            guard visited.count < 8, !visited.contains(offset) else { continue }
            visited.insert(offset)
            guard let parsed = readIFD(data, at: offset, little: little) else { continue }
            for (tag, value) in parsed.entries where entries[tag] == nil { entries[tag] = value }
            subIFDOffsets.append(contentsOf: parsed.subIFDs)
            pending.append(contentsOf: parsed.subIFDs)
            if let next = parsed.next, next != 0 { pending.append(Int(next)) }
        }
        _ = subIFDOffsets

        func numbers(_ tag: Tag) -> [Double]? {
            guard let value = entries[tag] else { return nil }
            return readNumbers(value, little: little)
        }

        var metadata = DNGMetadata(
            whiteLevel: numbers(.whiteLevel)?.first,
            blackLevel: numbers(.blackLevel) ?? [],
            baselineExposure: numbers(.baselineExposure)?.first,
            bitsPerSample: numbers(.bitsPerSample)?.first.map { Int($0) },
            // Tag 50706 is four BYTEs (major.minor.patch.build), not a string.
            dngVersion: numbers(.dngVersion).map { values in
                values.map { String(Int($0)) }.joined(separator: ".")
            },
            make: entries[.make].flatMap { readString($0) },
            model: entries[.model].flatMap { readString($0) },
            uniqueCameraModel: entries[.uniqueCameraModel].flatMap { readString($0) }
        )
        if !metadata.isDNG { metadata.dngVersion = nil }
        return metadata
    }

    private static func readIFD(_ data: Data, at offset: Int, little: Bool) -> (entries: [Tag: Value], next: UInt32?, subIFDs: [Int])? {
        guard let count = readUInt16(data, offset, little: little) else { return nil }
        var entries: [Tag: Value] = [:]
        var subIFDs: [Int] = []
        for index in 0..<Int(count) {
            let entry = offset + 2 + index * 12
            // A single unreadable entry must not discard the whole IFD: real
            // DNGs carry types this reader does not interpret, and aborting on
            // the first of them left every tag unread on a ProRAW.
            guard let tag = readUInt16(data, entry, little: little),
                  let typeRaw = readUInt16(data, entry + 2, little: little),
                  let type = FieldType(rawValue: typeRaw),
                  let n = readUInt32(data, entry + 4, little: little) else { continue }
            let count = Int(n)
            let total = type.size * count
            let payloadOffset: Int
            if total <= 4 {
                payloadOffset = entry + 8
            } else if let pointer = readUInt32(data, entry + 8, little: little) {
                payloadOffset = Int(pointer)
            } else {
                continue
            }
            guard total >= 0, payloadOffset >= 0, payloadOffset + total <= data.count else { continue }
            let bytes = data.subdata(in: payloadOffset..<(payloadOffset + total))
            guard let known = Tag(rawValue: tag) else { continue }
            entries[known] = Value(type: type, count: count, bytes: bytes)
            if known == .subIFDs {
                subIFDs = (0..<count).compactMap { index in
                    readUInt32(data, payloadOffset + index * 4, little: little).map(Int.init)
                }
            }
        }
        let nextOffset = offset + 2 + Int(count) * 12
        let next = readUInt32(data, nextOffset, little: little)
        return (entries, next, subIFDs)
    }

    private static func readNumbers(_ value: Value, little: Bool) -> [Double]? {
        var result: [Double] = []
        for index in 0..<value.count {
            switch value.type {
            case .byte, .undefined:
                result.append(Double(value.bytes[index]))
            case .sbyte:
                result.append(Double(Int8(bitPattern: value.bytes[index])))
            case .sshort:
                guard let raw = readUInt16(value.bytes, index * 2, little: little) else { return result }
                result.append(Double(Int16(bitPattern: raw)))
            case .slong:
                guard let raw = readInt32(value.bytes, index * 4, little: little) else { return result }
                result.append(Double(raw))
            case .float, .double:
                return result
            case .short:
                guard let raw = readUInt16(value.bytes, index * 2, little: little) else { return result }
                result.append(Double(raw))
            case .long:
                guard let raw = readUInt32(value.bytes, index * 4, little: little) else { return result }
                result.append(Double(raw))
            case .rational:
                guard let numerator = readUInt32(value.bytes, index * 8, little: little),
                      let denominator = readUInt32(value.bytes, index * 8 + 4, little: little),
                      denominator != 0 else { return result }
                result.append(Double(numerator) / Double(denominator))
            case .srational:
                guard let numerator = readInt32(value.bytes, index * 8, little: little),
                      let denominator = readInt32(value.bytes, index * 8 + 4, little: little),
                      denominator != 0 else { return result }
                result.append(Double(numerator) / Double(denominator))
            case .ascii:
                return nil
            }
        }
        return result
    }

    private static func readString(_ value: Value) -> String? {
        guard value.type == .ascii, let string = String(data: value.bytes, encoding: .utf8) else { return nil }
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Byte order

    private static func readUInt16(_ data: Data, _ offset: Int, little: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let b0 = UInt16(data[offset]), b1 = UInt16(data[offset + 1])
        return little ? (b1 << 8) | b0 : (b0 << 8) | b1
    }

    private static func readUInt32(_ data: Data, _ offset: Int, little: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = [UInt32(data[offset]), UInt32(data[offset + 1]), UInt32(data[offset + 2]), UInt32(data[offset + 3])]
        let ordered = little ? bytes.reversed() : bytes
        return ordered.reduce(0) { ($0 << 8) | $1 }
    }

    private static func readInt32(_ data: Data, _ offset: Int, little: Bool) -> Int32? {
        readUInt32(data, offset, little: little).map { Int32(bitPattern: $0) }
    }
}
