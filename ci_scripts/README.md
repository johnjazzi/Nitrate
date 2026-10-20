# Xcode Cloud bootstrap and beta workflow

## Why the first build failed

Cloud checked out `758be50`, which contains neither a generated
`Nitrate.xcodeproj` nor a post-clone script. The local project exists only because
XcodeGen generated it. It is intentionally Git-ignored: `project.yml` remains the
source of truth.

`ci_post_clone.sh` runs before package resolution. It downloads XcodeGen 2.46.0
and SwiftLint 0.65.1 from their upstream releases, verifies pinned SHA-256 digests,
and generates the project and shared Nitrate scheme. Tools are kept beneath the
ignored `build/ci-tools/` directory. No Homebrew, administrator access, repository
secrets, or vendored binary commit is needed.

The app's SwiftLint build phase explicitly includes the tool directory in PATH.
A post-clone script's exported PATH does not carry over into later independent
build processes. Do not silently skip lint when a tool is missing.

Only the Cloud checkout is prepared; this script does not commit or push a
project, change a developer account, create certificates, or publish a build.

## Post-xcodebuild iOS coverage

`ci_post_xcodebuild.sh` runs after `xcodebuild` for each action. Apple runs a
test action in two phases: it builds test products with
`xcodebuild build-for-testing` (source code available), then runs them with
`xcodebuild test-without-building` (source code unavailable). Because the
RenderCLI TEST action only compiles for macOS, this hook restores the iOS compile
the retired native job provided: when `CI_XCODEBUILD_ACTION` is
`build-for-testing` it re-adds the pinned tool paths and runs
`python3 scripts/verify.py check` (lint plus an unsigned generic iOS build).
Every other action and the `test-without-building` phase exit immediately. If the
source checkout is missing in that phase, the hook fails loudly instead of
silently dropping the coverage.

## Configure the existing Cloud workflow

In App Store Connect → Apps → nitrate.camera → Xcode Cloud → Workflows →
TestFlight → Edit (the workflow was originally named Default):

1. Start Conditions: add **Branch Changes → Custom Branches → main**. Manual
   Start may remain for explicit rebuilds. Do not enable distribution for every
   branch or Pull Request Changes. A PR opening does not release a beta; merging
   it changes main and triggers the release workflow.
2. Environment: choose an available Xcode with the iOS 27 SDK. For a candidate
   intended for external testing, enable Clean and restrict workflow editing as
   required by Apple's distribution workflow settings.
3. Actions: use **Archive**, iOS, scheme **Nitrate**, deployment preparation
   **TestFlight and App Store**. A Build action alone does not distribute an app.
   Do not choose Internal Testing Only if friends will test that same binary.
4. Add a TestFlight internal-testing post-action targeting **Personal Testing**
   (or the owner's actual chosen internal group).
   Keep external distribution manual until the owner's beta smoke test passes.
5. Save the workflow. Merge the reviewed release PR and confirm a **new** build
   starts automatically from that exact main merge SHA. Rebuilding an old failed
   commit does not pick up the new source.
6. In logs, require `Cloud bootstrap ready: Nitrate.xcodeproj, XcodeGen 2.46.0,
   SwiftLint 0.65.1` before successful dependency resolution.
7. In **TestFlight → iOS → Build Uploads**, require **Complete**, then verify the
   release version and Cloud build number, membership in Personal Testing, and
   availability in the TestFlight app. A successful archive or Cloud compile is
   not proof that delivery completed. Device auto-install also depends on the
   user's TestFlight Automatic Updates preference.

These are the desired account settings, not a claim that this repository can
read or save the live Apple workflow. Confirm Start Conditions and Post-Actions
in the signed-in owner session; an unauthenticated browser cannot verify them.

Use Xcode Cloud's build number for distributed builds; it increments independently
of the marketing version. The marketing version remains in `project.yml` and
must be bumped for a release PR. Check already-uploaded version/build pairs
before mixing manual and Cloud uploads. Do not hardcode the Cloud build number
in a post-clone script or overwrite it by editing the generated project later.

The local StoreKit run fixture is for local tests; it is not a requirement for
TestFlight and must not be bundled into the application.

Cloud must archive the **Nitrate** scheme, configuration **Release**, bundle ID
`com.nitrate.app`. **NitrateDev** archives DevRelease using
`com.nitrate.app.dev` and is not a TestFlight distribution scheme. The reviewed
export-compliance declaration is included in the generated plist; reassess it
if cryptographic behavior or dependencies change.

Prepare and validate the PR version with the commands in
[development and release builds](../docs/development.md). GitHub's release-version
check is separate from Apple's archive/upload workflow and does not auto-merge
or publish the PR.

## Local validation

```sh
python3 scripts/test_cloud_bootstrap.py
python3 scripts/test_verify_workflow.py
python3 scripts/verify.py verify
```

The behavior suite uses temporary fake tool executables only to exercise error
handling and path propagation without network access. A separate fresh-source
check must run the real bootstrap and then the same dependency-resolution
command as Cloud, without relying on a pre-existing local project.

Do not point a Cloud Test action at the entire local macOS suite until its
source-relative fixture reads have been adapted: Apple runs the test execution
phase without the source checkout. Camera smoke tests still require a physical
compatible iPhone regardless of where compilation runs.

## Tool updates

Update version directory names in the script and `project.yml`, upstream URLs,
archive digests, and behavior fixtures together. Obtain digests from the exact
upstream release asset, verify the downloaded bytes, then test generation and
lint before changing the pin. XcodeGen's release ZIP includes setting presets;
keep its directory layout rather than copying only the executable.

## References

- Apple: [Custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- Apple: [Project requirements](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud)
- Apple: [Workflow actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- Apple: [Distribution workflows](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)
- Apple: [Cloud build numbers](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)
- Apple: [Test execution and source availability](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)
- [SwiftLint 0.65.1](https://github.com/realm/SwiftLint/releases/tag/0.65.1)
