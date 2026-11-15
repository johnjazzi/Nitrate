import SwiftUI

/// The History delete controls, drawn as a stub.
///
/// Nothing here deletes anything: the sheet collects a scope and hands it to
/// `onRequest`, which the owner answers with an explicit "not enabled" notice.
/// It holds no queue reference, so it cannot touch a `RenderJob`, a retained
/// file, a hidden ID or a Photos record even by accident.
struct HistoryDeletionSheet: View {
    /// Called with the selected scope when the operator asks for a delete.
    var onRequest: (HistoryDeletionScope) -> Void
    /// Optional owner-supplied close. When absent the sheet dismisses itself,
    /// so it works both as a presented sheet and as an inline overlay.
    var onClose: (() -> Void)?

    @State private var selectedScope: HistoryDeletionScope = .olderThan30Days
    @State private var showsScopeInfo = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            scopePicker
            if showsScopeInfo {
                scopeInfo
            }
            Spacer(minLength: 8)
            deleteButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("queue.historyDelete")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Delete images")
                .font(NitrateTypography.font(.title3))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            infoButton
            Spacer(minLength: 4)
            closeButton
        }
    }

    /// Icon only, as asked: the copy itself lives in the reveal below it.
    private var infoButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                showsScopeInfo.toggle()
            }
        } label: {
            Image(systemName: showsScopeInfo ? "info.circle.fill" : "info.circle")
                .font(NitrateTypography.font(.body))
                .foregroundStyle(showsScopeInfo ? Color.white : Color.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete scope info")
        .accessibilityValue(showsScopeInfo ? "Shown" : "Hidden")
        .accessibilityHint("Shows what is kept when images are deleted.")
        .accessibilityIdentifier("queue.historyDelete.info")
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(NitrateTypography.font(.body))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close delete options")
        .accessibilityIdentifier("queue.historyDelete.close")
    }

    // MARK: - Scope

    private var scopePicker: some View {
        Picker("Delete scope", selection: $selectedScope) {
            ForEach(HistoryDeletionScope.allCases) { scope in
                Text(scope.title)
                    .font(NitrateTypography.font(.footnote))
                    .tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .tint(Color(white: 0.24))
        .accessibilityLabel("Delete scope")
        .accessibilityValue(selectedScope.title)
        .accessibilityIdentifier("queue.historyDelete.scope")
    }

    /// The one place the sheet is allowed to explain itself. The Photos
    /// sentence is the promise the owner asked for, word for word; the second
    /// line keeps the promise honest by saying the scope is local and inert.
    private var scopeInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Content won’t be deleted from Photos.")
                .font(NitrateTypography.font(.footnote))
                .foregroundStyle(.white.opacity(0.92))
            Text("Local history only. This control removes nothing yet.")
                .font(NitrateTypography.font(.caption2))
                .foregroundStyle(.white.opacity(0.6))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.historyDelete.info.copy")
        .transition(.opacity)
    }

    // MARK: - Request

    /// Looks destructive because it is the action the owner is asking about,
    /// but it only reports the selection; the owner answers with a stub notice.
    private var deleteButton: some View {
        Button {
            onRequest(selectedScope)
            close()
        } label: {
            Text("Delete")
                .font(NitrateTypography.font(.headline))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.72, green: 0.16, blue: 0.14)))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete \(selectedScope.title) of history")
        .accessibilityHint("Requests this scope. Nothing is deleted yet.")
        .accessibilityIdentifier("queue.historyDelete.confirm")
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
