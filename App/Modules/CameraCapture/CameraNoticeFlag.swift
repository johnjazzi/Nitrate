import SwiftUI

/// The camera's notice flag: a small solid icon that can be opened into the
/// full message and cleared by hand. It never blocks the viewfinder — the
/// panel is translucent and sized to the text.
struct CameraNoticeFlag: View {
    let notice: CameraNotice
    @Binding var isExpanded: Bool
    var onDismiss: () -> Void

    private var tint: Color {
        notice.severity == .warning ? .orange : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: notice.severity.symbolName)
                    .font(NitrateTypography.font(.footnote))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.opacity(0.9)))
                    .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("camera.notice")
            .accessibilityLabel("\(notice.severity.title): \(notice.message)")
            .accessibilityHint("Opens the message")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notice.severity.title.uppercased())
                        .font(NitrateTypography.font(.caption2).weight(.semibold))
                        .kerning(0.6)
                        .foregroundStyle(tint)
                    Text(notice.message)
                        .font(NitrateTypography.font(.footnote))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Clear") { onDismiss() }
                        .font(NitrateTypography.font(.caption).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                        .accessibilityIdentifier("camera.notice.clear")
                }
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .overlay { RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.25)) }
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("camera.notice.panel")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }
}
