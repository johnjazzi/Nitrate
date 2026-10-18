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

## Configure the existing Cloud workflow

In App Store Connect → nitrate.camera → Xcode Cloud → Workflows → Default:

1. Start conditions: initially Manual Start on the updated `main` branch. After
   the first successful beta delivery, use Branch Changes restricted to `main`
   if every reviewed merge should produce a beta. Do not distribute from every
   worker branch or PR.
2. Environment: choose an available Xcode with the iOS 27 SDK. For a candidate
   intended for external testing, enable Clean and restrict workflow editing as
   required by Apple's distribution workflow settings.
3. Actions: use **Archive**, iOS, scheme **Nitrate**, deployment preparation
   **TestFlight and App Store**. A Build action alone does not distribute an app.
   Do not choose Internal Testing Only if friends will test that same binary.
4. Add a TestFlight internal-testing post-action targeting the owner's group.
   Keep external distribution manual until the owner's beta smoke test passes.
5. Start a **new** build from the updated `main` head. Rebuilding the failed
   commit `758be50` cannot pick up this fix or the newer launch changes.
6. In logs, require `Cloud bootstrap ready: Nitrate.xcodeproj, XcodeGen 2.46.0,
   SwiftLint 0.65.1` before successful dependency resolution.
7. After Archive/export processing succeeds, verify the exact build appears
   under TestFlight, complete compliance requirements, and assign it to the
   test group if needed. A successful local archive or Cloud compile is not proof
   that TestFlight delivery completed.

Use Xcode Cloud's build number for distributed builds; it increments independently
of the marketing version. The marketing version remains in `project.yml` and
must be bumped for a release PR. Check already-uploaded version/build pairs
before mixing manual and Cloud uploads. Do not hardcode the Cloud build number
in a post-clone script or overwrite it by editing the generated project later.

The local StoreKit run fixture is for local tests; it is not a requirement for
TestFlight and must not be bundled into the application.

## Local validation

```sh
python3 scripts/test_cloud_bootstrap.py
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
