import SwiftUI

struct CameraStorageInfoSheet: View {
    let freeSpaceBytes: Int64?
    let totalSpaceBytes: Int64?
    let estimatedSeconds: TimeInterval?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                CameraStorageSummary(
                    freeSpaceBytes: freeSpaceBytes,
                    totalSpaceBytes: totalSpaceBytes,
                    estimatedSeconds: estimatedSeconds
                )
                .padding(.bottom, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Storage")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(9)
            }
            .buttonStyle(CameraRaisedButtonStyle(cornerRadius: 6))
            .accessibilityLabel("Close storage details")
        }
    }
}

/// Shared storage content without its own scrolling or presentation container.
struct CameraStorageSummary: View {
    let freeSpaceBytes: Int64?
    let totalSpaceBytes: Int64?
    let estimatedSeconds: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                storageRow("Available", value: formattedBytes(freeSpaceBytes))
                storageRow("Used", value: usedSpaceText)
                storageRow("Total", value: formattedBytes(totalSpaceBytes))
                Divider()
                storageRow("Estimated recording time", value: formattedDuration(estimatedSeconds))
            }

            Text("Estimate reserves 500 MB and allows for both the original and rendered copy. Photos copies and variable encoding can reduce actual time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usedSpaceText: String {
        guard let freeSpaceBytes, let totalSpaceBytes else { return "Unavailable" }
        return formattedBytes(max(0, totalSpaceBytes - freeSpaceBytes))
    }

    private func storageRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func formattedBytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "Unavailable" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Unavailable" }
        if seconds == 0 { return "0 min" }
        guard seconds >= 60 else { return "<1 min" }

        let minutes = Int(min(seconds / 60, 10_000_000))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours >= 24 {
            return "~\(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "~\(hours)h \(remainingMinutes)m"
        }
        return "~\(minutes)m"
    }
}
