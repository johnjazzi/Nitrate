import Foundation

/// One compact metadata card: a rounded group of label-over-value rows.
///
/// The cards read only from the job and its receipt, never from the live stock
/// catalog or the Photos library, so a card states what the delivered file
/// says rather than what today's settings would produce.
struct MetadataCell: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

struct MetadataRow: Identifiable, Equatable {
    let id: String
    let cells: [MetadataCell]
}

struct MetadataCard: Identifiable, Equatable {
    let id: String
    var rows: [MetadataRow]
    /// A notes card renders one wide text field instead of cells.
    var notes: String? = nil
}

/// Builds the metadata cards for a delivered video or photo from the same
/// receipt the queue already keeps.
enum ReceiptMetadataCards {
    /// Shown where the file or the capture genuinely has no such value (a still
    /// has no frame rate). Never a zero, which would read as a measurement.
    static let missing = "—"

    static func make(job: RenderJob) -> [MetadataCard] {
        let receipt = job.receipt
        let metadata = receipt?.metadata ?? [:]
        let isPhoto = job.isPhoto == true

        let delivered = MetadataRow(id: "delivered", cells: [
            MetadataCell(id: "proxy", label: isPhoto ? "Delivered" : "Proxy",
                         value: codecName(receipt?.codec)),
            MetadataCell(id: "proxy-fps", label: "Frame Rate",
                         value: isPhoto ? missing : frameRate(receipt?.framesPerSecond)),
            MetadataCell(id: "proxy-resolution", label: "Resolution",
                         value: resolution(receipt?.pixelWidth, receipt?.pixelHeight)),
            MetadataCell(id: "proxy-size", label: "File Size", value: fileSize(receipt?.fileSizeBytes))
        ])

        let original = MetadataRow(id: "original", cells: [
            MetadataCell(id: "original-codec", label: isPhoto ? "Original RAW" : "Original Video",
                         value: codecName(receipt?.original?.codec)),
            MetadataCell(id: "original-fps", label: "Frame Rate",
                         value: isPhoto ? missing : frameRate(receipt?.original?.framesPerSecond)),
            MetadataCell(id: "original-resolution", label: "Resolution",
                         value: resolution(receipt?.original?.pixelWidth, receipt?.original?.pixelHeight)),
            MetadataCell(id: "original-size", label: "File Size", value: fileSize(receipt?.original?.fileSizeBytes))
        ])

        let created = MetadataRow(id: "created", cells: [
            MetadataCell(id: "created-at", label: "Created", value: createdDate(receipt, job: job))
        ])

        let exposure = MetadataRow(id: "exposure", cells: [
            MetadataCell(id: "shutter", label: "Shutter", value: shutter(metadata)),
            MetadataCell(id: "iris", label: "Iris", value: iris(metadata)),
            MetadataCell(id: "iso", label: "ISO", value: text(metadata["com.filmemulation.iso"])),
            MetadataCell(id: "wb", label: "WB", value: text(metadata["com.filmemulation.white-balance-kelvin"])),
            MetadataCell(id: "tint", label: "Tint", value: text(metadata["com.filmemulation.wb-tint"]))
        ])

        // The resolved value, not the stored preference: the receipt keeps what
        // the render wrote, and the job is the fallback for a job with no
        // receipt yet.
        let pushPull = MetadataRow(id: "push-pull", cells: [
            MetadataCell(id: "push-pull-value", label: "Push / Pull",
                         value: pushPullValue(metadata, job: job))
        ])

        let colorSpace = MetadataRow(id: "color-space", cells: [
            MetadataCell(id: "color-space-value", label: "Color Space", value: text(metadata["com.filmemulation.color-space"]))
        ])

        let lens = MetadataRow(id: "lens", cells: [
            MetadataCell(id: "lens-value", label: "Lens Data", value: lensValue(metadata))
        ])

        let slate = MetadataRow(id: "slate", cells: [
            MetadataCell(id: "reel", label: "Reel", value: text(metadata["com.filmemulation.reel"])),
            MetadataCell(id: "scene", label: "Scene", value: text(metadata["com.filmemulation.scene"])),
            MetadataCell(id: "take", label: "Take", value: text(metadata["com.filmemulation.take"]))
        ])

        return [
            MetadataCard(id: "file", rows: [delivered, original, created]),
            MetadataCard(id: "exposure", rows: [exposure, pushPull]),
            MetadataCard(id: "color", rows: [colorSpace]),
            MetadataCard(id: "lens", rows: [lens, slate]),
            MetadataCard(id: "notes", rows: [], notes: "")
        ]
    }

    // MARK: - Formatting

    /// The container's short name: `hvc1` is H.265 to everyone who reads a file.
    static func codecName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return missing }
        switch raw.lowercased() {
        case "hvc1", "hev1": return "H.265"
        case "avc1": return "H.264"
        case "public.jpeg", "jpeg", "jpg": return "JPEG"
        case "com.adobe.raw-image", "dng": return "DNG"
        case "public.heic", "heic": return "HEIC"
        default: return raw.uppercased()
        }
    }

    static func frameRate(_ fps: Double?) -> String {
        guard let fps, fps.isFinite, fps > 0 else { return missing }
        return fps.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...2)))
    }

    static func resolution(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height, width > 0, height > 0 else { return missing }
        return "\(width) x \(height)"
    }

    static func fileSize(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return missing }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 0.01 {
            return String(format: "%.2f MB", megabytes)
        }
        return "\(bytes) B"
    }

    /// A video states the 180° shutter angle; a still states its real exposure
    /// time, because a photo has no frame rate to relate the angle to.
    static func shutter(_ metadata: [String: String]) -> String {
        if let angle = metadata["com.filmemulation.shutter-angle"], !angle.isEmpty,
           angle != "unknown-or-not-recorded" {
            return "\(angle)°"
        }
        let speed = metadata["com.filmemulation.shutter-speed"]
        return speed == "unknown-or-not-recorded" ? missing : text(speed)
    }

    static func iris(_ metadata: [String: String]) -> String {
        guard let raw = metadata["com.filmemulation.aperture-f-number"],
              let value = Double(raw), value.isFinite, value > 0 else { return missing }
        return "f/" + value.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0...5)))
    }

    static func lensValue(_ metadata: [String: String]) -> String {
        let lens = metadata["com.filmemulation.lens"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let focal = metadata["com.filmemulation.focal-length-mm"].flatMap(Double.init)
        let millimeters = focal.flatMap { $0.isFinite && $0 > 0
            ? $0.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(0...1)))
            : nil }
        if let lens, !lens.isEmpty {
            guard let millimeters, !lens.lowercased().contains("mm") else { return lens }
            return "\(lens) \(millimeters)mm"
        }
        return millimeters.map { "\($0)mm" } ?? missing
    }

    /// "PULL -2", "PUSH +1" or "0" for a neutral render.
    static func pushPullValue(_ metadata: [String: String], job: RenderJob) -> String {
        if let raw = metadata["com.filmemulation.push-pull-stops"], let value = Int(raw) {
            let stops = PushPullStops.nearest(to: value)
            return stops.effectWord == "0" ? "0" : "\(stops.effectWord) \(stops.displayName)"
        }
        if let stops = job.pushPull?.stops {
            return stops.effectWord == "0" ? "0" : "\(stops.effectWord) \(stops.displayName)"
        }
        // A job that has not delivered yet is queued neutral; a delivered
        // receipt that omits the key is a legacy file whose state is unknown.
        return job.receipt == nil ? "0" : missing
    }

    static func createdDate(_ receipt: RenderReceipt?, job: RenderJob) -> String {
        (receipt?.recordedAt ?? job.createdAt).formatted(date: .long, time: .shortened)
    }

    static func text(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return missing
        }
        return value
    }
}