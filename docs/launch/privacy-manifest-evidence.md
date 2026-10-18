# Privacy manifest implementation evidence

Source base before other launch fixes: `b7e7967`. This records required-reason API inventory and manifest tests, not App Store validation or a complete legal privacy policy.

| Bundled category | Reason | Observed use |
|---|---|---|
| UserDefaults | `CA92.1` | App-owned stock, gauge, camera, purchase and presentation preferences, including `@AppStorage`. No shared/global preference domains found in app code. |
| SystemBootTime | `35F9.1` | In-app splash/frame/drop timing using `ProcessInfo.systemUptime`; elapsed-time/timer use, not device fingerprinting. |
| DiskSpace | `85F4.1` | Display available/total space and estimated recording time to the user. |
| DiskSpace | `E174.1` | Low/critical storage checks affect recording availability and show warnings. |
| FileTimestamp | `C617.1` | `attributesOfItem` reads metadata/size for original and output files inside the app container. No user-imported arbitrary file route is claimed. |

These approved-reason meanings were checked against Apple's current required-reason API documentation, retrieved as its structured documentation JSON. They must be revisited if API use or off-device reporting changes.[22]

The manifest declares tracking false, empty tracking domains and no app-collected data types. This reflects the reviewed app-operated code paths, not a claim that Apple services, purchases, Photos synchronization or TestFlight feedback collect no information. Privacy policy, App Store privacy answers and beta-service disclosures still need their own factual/account review.[4][14]

`App/PrivacyInfo.xcprivacy` is discovered as a resource by the recursive App target in XcodeGen. `Tests/PrivacyManifestTests.swift` pins the exact category/reason set and declarations. The test was run against the missing manifest (one failure), then against the added plist (one pass). `plutil -lint` passed; generated `.pbxproj` contains the manifest in Resources. Actual signed Debug app packaging was then inspected: the bundled manifest parses identically to source. Full RenderCLI verification passed 360 tests, unsigned iOS build and signed device build passed. The run first exposed an existing marker-render fixture's reliance on semantic system red; its screenshot showed the face present but outside the test's strict RGB threshold. The fixture now uses literal sRGB red without weakening the geometry assertion. Release archive packaging, privacy report and upload validation remain separate acceptance gates.

The public policy's contact/retention/delete details are not invented here. Do not automatically publish this implementation note as the legal privacy policy.

## Sources

[4] https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
[14] https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight
[22] https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
