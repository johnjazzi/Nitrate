import Foundation
import Testing

/// The DNG tag reader, exercised against a hand-built TIFF so the parser is
/// covered by something other than a camera's file.
///
/// The layout matters: WhiteLevel lives in the SubIFD of a real DNG (the raw IFD),
/// not in IFD0, so the walker has to follow tag 330. The tests below put a value
/// in each place and check that the reader finds it in both.
struct DNGMetadataTests {

    // MARK: - Synthetic TIFF

    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var inline: [UInt8]?
        var external: [UInt8]?

        init(_ tag: UInt16, _ type: UInt16, _ count: UInt32,
             inline: [UInt8]? = nil, external: [UInt8]? = nil) {
            self.tag = tag; self.type = type; self.count = count
            self.inline = inline; self.external = external
        }
    }

    /// Builds a little-endian TIFF with a SubIFD followed by IFD0.
    ///
    /// The SubIFD goes first so IFD0 can inline its tag-330 pointer without any
    /// back-patching: every offset is decided before a byte is written.
    private static func tiff(ifd0: [Entry], subIFD: [Entry]) -> Data {
        func blockSize(_ entries: [Entry]) -> Int { 2 + entries.count * 12 + 4 }
        let subOffset = 8
        let ifd0Offset = subOffset + blockSize(subIFD)
        var cursor = ifd0Offset + blockSize(ifd0)
        // External payloads are laid out in a fixed order, so each entry can be
        // formatted with its final pointer already known.
        var externalOffsets: [String: Int] = [:]
        func plan(_ entries: [Entry], group: Int) {
            for (index, entry) in entries.enumerated() where entry.external != nil {
                externalOffsets["\(group)-\(index)"] = cursor
                cursor += entry.external?.count ?? 0
            }
        }
        plan(subIFD, group: 0)
        plan(ifd0, group: 1)

        var bytes = [UInt8](repeating: 0, count: cursor)
        func put16(_ value: UInt16, _ at: Int) {
            bytes[at] = UInt8(value & 0xFF); bytes[at + 1] = UInt8(value >> 8)
        }
        func put32(_ value: UInt32, _ at: Int) {
            bytes[at] = UInt8(value & 0xFF); bytes[at + 1] = UInt8((value >> 8) & 0xFF)
            bytes[at + 2] = UInt8((value >> 16) & 0xFF); bytes[at + 3] = UInt8(value >> 24)
        }
        bytes[0] = 0x49; bytes[1] = 0x49
        put16(42, 2)
        put32(UInt32(ifd0Offset), 4)

        func write(_ entries: [Entry], at offset: Int, group: Int) {
            put16(UInt16(entries.count), offset)
            for (index, entry) in entries.enumerated() {
                let at = offset + 2 + index * 12
                put16(entry.tag, at)
                put16(entry.type, at + 2)
                put32(entry.count, at + 4)
                if let inline = entry.inline {
                    for (i, byte) in inline.enumerated() { bytes[at + 8 + i] = byte }
                } else if let external = entry.external, let destination = externalOffsets["\(group)-\(index)"] {
                    put32(UInt32(destination), at + 8)
                    for (i, byte) in external.enumerated() { bytes[destination + i] = byte }
                }
            }
        }
        write(subIFD, at: subOffset, group: 0)
        write(ifd0, at: ifd0Offset, group: 1)
        return Data(bytes)
    }

    private static func ascii(_ string: String) -> [UInt8] { Array(string.utf8) + [0] }
    private static func short(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private static func srational(_ value: Double) -> [UInt8] {
        func le(_ v: Int32) -> [UInt8] {
            let u = UInt32(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
        }
        return le(Int32((value * 1000).rounded())) + le(1000)
    }

    // MARK: - Reading

    /// In a real DNG the SubIFD offset is not at 8 — always compute it from the
    /// SubIFD's own block size instead of hardcoding a position.
    @Test
    func readsTheDNGTagsFromIfdZeroAndItsSubIfd() throws {
        let subIFD = [
            Entry(50714, 3, 1, inline: Self.short(528)),    // BlackLevel
            Entry(50717, 3, 1, inline: Self.short(4095))    // WhiteLevel
        ]
        // SubIFD sits at 8; IFD0 follows it, so tag 330 inlines its offset.
        let data = Self.tiff(ifd0: [
            Entry(271, 2, 6, external: Self.ascii("Apple")),      // Make
            Entry(272, 2, 6, external: Self.ascii("iPhone")),     // Model
            Entry(330, 4, 1, inline: [8, 0, 0, 0]),               // SubIFDs -> 8
            Entry(50706, 1, 4, inline: [1, 6, 0, 0]),             // DNGVersion 1.6.0.0
            Entry(50730, 10, 1, external: Self.srational(2.988))  // BaselineExposure
        ], subIFD: subIFD)

        let metadata = try #require(DNGMetadata.parse(data))
        #expect(metadata.isDNG)
        #expect(metadata.make == "Apple")
        #expect(metadata.model == "iPhone")
        #expect(metadata.whiteLevel == 4095)
        #expect(metadata.blackLevel == [528])
        // Explicitly Double: `Optional<Double> == Int` compares false even when
        // the numbers are equal, which is a trap worth pinning here.
        #expect(metadata.usableWhiteLevel == 3567.0)
        #expect(abs((metadata.baselineExposure ?? 0) - 2.988) < 0.002)
    }

    /// A raw that is not a DNG (NEF, ARW, CR3) has no DNG tags, and the reader
    /// must say so rather than inventing numbers from some other IFD.
    @Test
    func nonDNGReportsNoDNGFields() throws {
        let data = Self.tiff(ifd0: [Entry(271, 2, 6, external: Self.ascii("NIKON"))], subIFD: [])
        let metadata = try #require(DNGMetadata.parse(data))
        #expect(metadata.isDNG == false)
        #expect(metadata.whiteLevel == nil)
        #expect(metadata.baselineExposure == nil)
        #expect(metadata.make == "NIKON")
    }

    /// Anything that is not a TIFF is refused, so a JPEG or HEIC that reached the
    /// entry gate by name cannot be read as a raw.
    @Test
    func refusesFilesThatAreNotTIFF() {
        #expect(DNGMetadata.parse(Data([0xFF, 0xD8, 0xFF, 0xE0])) == nil)
        #expect(DNGMetadata.parse(Data()) == nil)
        #expect(DNGMetadata.parse(Data([0x49, 0x49, 0x2A])) == nil)
    }

    /// Big-endian ("MM") files exist in the wild; the same tags must read.
    @Test
    func readsBigEndianFiles() throws {
        var bytes: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        bytes += [0x00, 0x01]                       // one entry
        bytes += [0xC6, 0x1D]                       // 50717 WhiteLevel
        bytes += [0x00, 0x03]                       // SHORT
        bytes += [0x00, 0x00, 0x00, 0x01]           // count 1
        bytes += [0x3F, 0xFF, 0x00, 0x00]           // 16383, inline
        bytes += [0x00, 0x00, 0x00, 0x00]           // no next IFD
        let metadata = try #require(DNGMetadata.parse(Data(bytes)))
        #expect(metadata.whiteLevel == 16383)
    }

    /// A tag whose payload runs past the end of the file must be dropped, not
    /// read off the end of the buffer.
    @Test
    func refusesPointersThatLeaveTheFile() throws {
        // WhiteLevel declared as 400 SHORTs at an offset past the file.
        var bytes: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]
        bytes += [0x01, 0x00]
        bytes += [0x1D, 0xC6, 0x03, 0x00, 0x90, 0x01, 0x00, 0x00]
        bytes += [0xFF, 0xFF, 0x00, 0x00]           // offset 65535, well past EOF
        bytes += [0x00, 0x00, 0x00, 0x00]
        let metadata = DNGMetadata.parse(Data(bytes))
        #expect(metadata?.whiteLevel == nil, "an out-of-range pointer must not produce a value")
    }
}
