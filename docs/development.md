# Development and release builds

`project.yml` is authoritative. Regenerate the ignored Xcode project with
`xcodegen generate`; do not make lasting configuration edits only in Xcode.

## Two installed apps

| Configuration | Bundle identifier | Home-screen name | Purpose |
| --- | --- | --- | --- |
| Debug | `com.nitrate.app.dev` | Nitrate Dev | Everyday local development |
| DevRelease | `com.nitrate.app.dev` | Nitrate Dev | Local release-optimized testing, without DEBUG features |
| Release | `com.nitrate.app` | Nitrate | Cloud/TestFlight/App Store distribution |

The local app and production app have separate containers, queues, preferences,
and permissions. Existing production footage does not migrate into Nitrate Dev.
Do not uninstall either app to switch between them. A local install can still
replace an earlier **Nitrate Dev**, but must not replace **Nitrate**.

### Run locally from Xcode

1. Return to the main project window, not Organizer.
2. Choose **Product → Scheme → NitrateDev**.
3. Choose **Product → Destination → your physical iPhone**.
4. Choose **Product → Run** (Command-R).
5. Confirm the installed app is **Nitrate Dev**.

To run the local app with Release compiler behavior:

1. With NitrateDev selected, choose **Product → Scheme → Edit Scheme**.
2. Select **Run → Info → Build Configuration → DevRelease**.
3. Close the sheet and run. Switch back to Debug for everyday debugging.

NitrateDev's Profile and Archive actions also use DevRelease. The **Nitrate**
scheme's Archive action remains Release for Cloud distribution. Do not manually
install a Release build of `com.nitrate.app` for routine testing.

The shared StoreKit configuration is a local testing fixture, not a shipped
subscription entitlement or proof that account products exist.

### Command-line verification

```sh
python3 scripts/verify.py verify
python3 scripts/verify.py device
```

The device command builds signed Debug, now the local dev identity. Its artifact
path remains `build/verification/DerivedData/Build/Products/Debug-iphoneos/Nitrate.app`.
Inspect its `Info.plist` before installation. Use the paired physical device ID:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device <device-id> \
  build/verification/DerivedData/Build/Products/Debug-iphoneos/Nitrate.app
xcrun devicectl device process launch --device <device-id> com.nitrate.app.dev
```

Keep the phone connected, trusted and unlocked. A successful signed build is not
proof of installation, app coexistence, or physical-camera behavior.

Agents share the verification build lock. Direct xcodebuild commands using the
same DerivedData must honor it too; never run simultaneous builds against that
folder. Do not clear another active agent's build outputs.

## Version convention: M.m.p (n)

- **M.m.p** is `MARKETING_VERSION` / `CFBundleShortVersionString`.
- **(n)** is `CURRENT_PROJECT_VERSION` / `CFBundleVersion` for manual builds.
- Each release PR into main advances patch by default.
- A `release:minor` or `release:major` PR label requests that larger increment.
  Do not combine bump labels. No label means patch.
- Each manual distribution rebuild advances the build, not the patch again.
- Ordinary Debug/DevRelease development compiles do not require a version bump.
- Cloud automatically assigns its own increasing integer to distributed builds.
  Do not overwrite Cloud's counter. Its raw archive may still show the source
  build number before export; verify the distributed build in TestFlight.

### Prepare a release PR

From dev, fetch the release base and prepare the source metadata:

```sh
git fetch origin main
python3 scripts/release_version.py prepare --base origin/main
python3 scripts/release_version.py check --base origin/main
xcodegen generate
```

Prepare is idempotent relative to that base: rerunning it does not keep advancing
an already-prepared PR. Review the diff and commit the metadata with the release.
For a minor or major release, pass matching labels to prepare/check, for example
`--labels '["release:minor"]'`, and apply the same label to the GitHub PR.

For a manual production distribution rebuild only:

```sh
python3 scripts/release_version.py bump-build
xcodegen generate
```

Before any manual upload, check the highest build already uploaded for that
version in App Store Connect. The helper increments the local source number; it
cannot discover or reserve Apple's remote counter. Prefer Cloud as the single
normal TestFlight uploader to avoid collisions between manual and Cloud uploads.
Never edit an already-created archive to change its version or identifier.

### PR gate versus automatic edits

`.github/workflows/release-version.yml` checks main-targeted PRs. It runs the
helper tests and requires the exact next release version plus an advanced source
build. Label changes retrigger it. The workflow is read-only: it does not edit
branches, commit, push, or merge. Run prepare before the PR; the coordinating
agent owns that release-preparation step.

Making **Release version gate** a required main-branch status check is a separate
GitHub repository setting. A workflow file alone does not stop an owner from
merging a failing check. After a real PR has run it, require that exact check,
require branches to be up to date with main before merging, and require
PR-based merges. An earlier pass against an old base does not validate the next
release version after another PR merges. Do not require the post-merge Cloud
archive to pass on PRs: it runs only after main changes.

## Cloud distribution

The intended path is:

`release PR → main merge → Cloud Archive → upload/processing → TestFlight group`

The Cloud settings live in the Apple account, not in this repository. See
[Cloud setup](../ci_scripts/README.md) for exact owner-side settings and the
end-to-end acceptance check. Local validation, an uploaded workflow file, or a
passing GitHub version gate does not establish successful TestFlight delivery.
