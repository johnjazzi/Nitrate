import SwiftUI

/// A recessed, monochrome camera LCD. The caller supplies the real storage
/// estimate; the display adds no simulated battery or capacity readings.
struct RecordingTimeLCD: View {
    let estimatedSeconds: TimeInterval?
    let isStorageLow: Bool

    private var ink: Color {
        isStorageLow
            ? Color(red: 0.55, green: 0.06, blue: 0.04)
            : Color(red: 0.12, green: 0.16, blue: 0.10)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                Text("REC LEFT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                Spacer(minLength: 0)
                Text("EST")
                    .font(.system(size: 6, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(ink)

            SevenSegmentReadout(text: Self.timeText(for: estimatedSeconds), ink: ink)
                .frame(height: 20)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(
                    colors: [Color(red: 0.53, green: 0.57, blue: 0.45),
                             Color(red: 0.65, green: 0.68, blue: 0.56)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(LinearGradient(
                            colors: [.black.opacity(0.6), .black.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ), lineWidth: 1)
                }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.13))
                .overlay {
                    // Recessed rather than raised: dark upper lip, lit lower lip.
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(LinearGradient(
                            colors: [.black.opacity(0.9), .white.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        ), lineWidth: 1)
                }
        }
    }

    /// Keep seconds visible and include hours when necessary, rather than
    /// wrapping a long estimate into minutes or silently truncating it.
    static func timeText(for seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds < Double(Int.max) else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%ld:%02ld:%02ld", hours, minutes, remainder)
        }
        return String(format: "%02ld:%02ld", minutes, remainder)
    }
}

/// Seven-segment glyphs drawn in normalized coordinates, without a custom font.
/// All seven segments stay faintly visible like the electrodes in a real LCD.
private struct SevenSegmentReadout: View {
    let text: String
    let ink: Color

    private static let masks: [Character: Int] = [
        "0": 0b0111111, "1": 0b0000110, "2": 0b1011011,
        "3": 0b1001111, "4": 0b1100110, "5": 0b1101101,
        "6": 0b1111101, "7": 0b0000111, "8": 0b1111111,
        "9": 0b1101111, "-": 0b1000000
    ]

    var body: some View {
        Canvas { context, size in
            let glyphs = Array(text)
            let width = glyphs.reduce(CGFloat.zero) { $0 + ($1 == ":" ? 4 : 10) }
                + CGFloat(max(0, glyphs.count - 1)) * 2
            let scale = min(size.width / max(width, 1), size.height / 20)
            context.translateBy(x: (size.width - width * scale) / 2,
                                y: (size.height - 20 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            var offset: CGFloat = 0
            for glyph in glyphs {
                if glyph == ":" {
                    for y in [CGFloat(6), CGFloat(13)] {
                        let dot = Path(CGRect(x: offset + 1, y: y, width: 2, height: 2))
                        context.fill(dot, with: .color(ink))
                    }
                    offset += 6
                } else {
                    let mask = Self.masks[glyph] ?? 0
                    for segment in 0..<7 {
                        let path = Self.segmentPath(segment)
                            .applying(CGAffineTransform(translationX: offset, y: 0))
                        let isActive = mask & (1 << segment) != 0
                        context.fill(path, with: .color(ink.opacity(isActive ? 1 : 0.07)))
                    }
                    offset += 12
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func segmentPath(_ segment: Int) -> Path {
        // Clockwise from the upper horizontal: top, upper-right, lower-right,
        // bottom, lower-left, upper-left, then the center horizontal.
        switch segment {
        case 0: return horizontalSegment(y: 0)
        case 1: return verticalSegment(x: 8, y: 1)
        case 2: return verticalSegment(x: 8, y: 10)
        case 3: return horizontalSegment(y: 18)
        case 4: return verticalSegment(x: 0, y: 10)
        case 5: return verticalSegment(x: 0, y: 1)
        default: return horizontalSegment(y: 9)
        }
    }

    private static func horizontalSegment(y: CGFloat) -> Path {
        polygon([
            CGPoint(x: 1.2, y: y + 1), CGPoint(x: 2.2, y: y),
            CGPoint(x: 7.8, y: y), CGPoint(x: 8.8, y: y + 1),
            CGPoint(x: 7.8, y: y + 2), CGPoint(x: 2.2, y: y + 2)
        ])
    }

    private static func verticalSegment(x: CGFloat, y: CGFloat) -> Path {
        polygon([
            CGPoint(x: x + 1, y: y), CGPoint(x: x + 2, y: y + 1.2),
            CGPoint(x: x + 2, y: y + 6.8), CGPoint(x: x + 1, y: y + 8),
            CGPoint(x: x, y: y + 6.8), CGPoint(x: x, y: y + 1.2)
        ])
    }

    private static func polygon(_ points: [CGPoint]) -> Path {
        Path { path in
            path.addLines(points)
            path.closeSubpath()
        }
    }
}
