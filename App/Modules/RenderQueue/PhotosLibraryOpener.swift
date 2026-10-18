import UIKit

/// Best-effort general handoff, not a documented guarantee of asset navigation.
/// Opens directly: no Photos reads and no canOpenURL/query-scheme requirement.
@MainActor
enum PhotosLibraryOpener {
    static let failureMessage = "Photos could not be opened from Nitrate. Open Photos manually and look in Recently Saved for videos whose save was confirmed."

    static func open() async -> Bool {
        guard let url = URL(string: "photos-redirect://") else { return false }
        return await UIApplication.shared.open(url, options: [:])
    }
}
