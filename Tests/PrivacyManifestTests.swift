import Foundation
import Testing

struct PrivacyManifestTests {
    @Test func appManifestDeclaresOnlyObservedAccessAndNoTracking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("App/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: url)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)
        let entries = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: Set<String>] = [:]
        for entry in entries {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            #expect(declared[category] == nil, "An accessed API category must appear only once.")
            declared[category] = Set(try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        }
        #expect(declared == [
            "NSPrivacyAccessedAPICategoryUserDefaults": Set(["CA92.1"]),
            "NSPrivacyAccessedAPICategorySystemBootTime": Set(["35F9.1"]),
            "NSPrivacyAccessedAPICategoryDiskSpace": Set(["85F4.1", "E174.1"]),
            "NSPrivacyAccessedAPICategoryFileTimestamp": Set(["C617.1"])
        ])
    }
}
