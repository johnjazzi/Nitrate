# CI migration

## Target split

- **GitHub/Linux:** the required **Xcode build and tests** check is an Ubuntu
  monitor (`.github/workflows/xcode.yml`) that starts and supervises a Cloud
  RenderCLI TEST run; the release-version gate and the portable Python policy
  tests run here too.
- **Xcode Cloud:** one macOS `RenderCLI` Test action for validation, plus
  `ci_scripts/ci_post_xcodebuild.sh` restoring the iOS lint/compile; a separate
  production `Nitrate` Archive workflow for merge-to-TestFlight delivery.
- The test monitor is now automatic (same-repo PR to main, manual
  dispatch). The release archive monitor stays manual
  (`.github/workflows/cloud.yml`).
- The replacement reuses the existing required check name, so no
  branch-protection setting changes. Do not leave a gap in required native
  validation.

## Implemented cutover (repository side)

- `.github/workflows/xcode.yml` replaces the native macOS job with a job named
  **Xcode build and tests** on `ubuntu-latest`. It checks out the monitor helper
  from the fixed reviewed commit `05993dd` (full SHA, never the PR head),
  installs the hash-pinned monitor dependencies, runs the monitor unit tests, and
  then starts/monitors the Cloud TEST run. The private key is scoped to the
  single start step. The helper commit is deliberately pinned; advance it only
  after review.
- Fork pull requests **fail** the check explicitly (never silently skip): fork
  PRs never receive the secrets and their head branch is not in this repository.
  The refusal step runs before any secret is read.
- The PR head branch is built with `--branch` (the Cloud manual workflow supports
  a branch, not a PR), and `--expected-sha` is the exact head commit.
- `ci_scripts/ci_post_xcodebuild.sh` restores the iOS lint/compile the native job
  used to provide. Apple runs a test action in two phases — `build-for-testing`
  (source available) then `test-without-building` (source unavailable) — so the
  hook runs only when `CI_XCODEBUILD_ACTION == build-for-testing` and then runs
  `python3 scripts/verify.py check`.
- Every Cloud monitor shares one product-wide `cloud-monitor` concurrency group
  with `cancel-in-progress: false`.
- The duplicate manual TEST launcher was removed from `cloud.yml`; it now
  supervises the release archive only.

## Budget policy: alert, not an automatic stop

The owner explicitly accepted **10-minute alerts and manual cancellation**, not
an enforced whole-run timeout.

Apple's official App Store Connect OpenAPI 4.5.1 exposes build-run creation and
reads, but no cancellation operation or total-run timeout field. `cancelReason`
is read-only; it does not make PATCH or DELETE available. Recheck the current
[official specification](https://developer.apple.com/app-store-connect/api/)
before changing this design.

At the deadline, monitoring must fail and state that **Cloud may still be
running and needs manual cancellation**. A failed or cancelled GitHub monitor
is not proof that Apple's build stopped. There are no automatic build retries.
A pending/running Cloud build blocks another monitored launch. Native Cloud
start conditions must be manual-only while the external orchestrator supervises
launches; do not allow unmonitored duplicate launches.

Use one action and one destination per workflow. Cloud compute usage sums
parallel work and is not the same as elapsed wall time. Alerts do not guarantee
that a run uses only ten compute minutes or that the monthly 25-hour allowance
cannot be exhausted. No paid-plan upgrade is authorized by this migration.

## Portable repository checks

`.github/workflows/policy.yml` declares `Repository policy checks` on
`ubuntu-latest`, capped at ten minutes for the entire job. It uses read-only
repository permission, pinned checkout without persisted credentials, and
cancels superseded **policy** jobs. Cloud monitors must not inherit that
cancellation policy because terminating a monitor does not stop Cloud.

The portable job explicitly runs:

- `scripts/test_release_version.py`
- `scripts/test_cloud_bootstrap.py` (fake tool commands, no downloads)
- `scripts/test_package_test_fixtures.py`
- `scripts/test_ci_policy.py`

`test_dev_identity.py` and `test_release_metadata.py` need XcodeGen/plutil;
`test_verify_workflow.py` exercises native process/watchdog behavior. They remain
native checks, not silently skipped Linux tests. A local macOS pass is not an
executed Ubuntu result.

## Checkout-free native tests

Cloud test execution has no source checkout. `scripts/package_test_fixtures.py`
packages an allowlisted source/configuration snapshot into the **test bundles**
at build time. `Tests/TestRepository.swift` resolves source-contract fixtures
from that snapshot. Nothing is added to the shipping application's resources.

Keep ordinary bundled LUT/grain resources separate from the source-contract
snapshot. Fail on missing/unsafe fixtures rather than skipping assertions.
Validate the actual built snapshot and run the suite using it; source contracts
and Python packaging tests alone do not establish Cloud success.

## Live setup and cutover gates

1. Authenticate App Store Connect and inspect the existing Cloud workflows.
   Do not infer saved settings from repository scripts.
2. Configure a validation workflow with the `RenderCLI` scheme, one macOS test
   destination, no automatic retry, and no native automatic start condition.
3. Configure release separately: production `Nitrate` Archive scheme and the
   intended TestFlight group. PR validation must not distribute a beta.
4. Configure credentials through secure GitHub Secrets, never repository files
   or chat. Record workflow IDs as repository variables.
5. Exercise the monitor against a live exact-commit Cloud run. Confirm its
   deadline notification and manual-cancellation instructions. Confirm actual
   successful tests separately from a successful archive/upload.
6. Confirm the automatic test monitor ran on a real same-repo PR to main and a
   manual dispatch, and that a fork PR fails as intended. Main pushes retain
   the existing automatic TestFlight archive; no duplicate test run competes
   with it for the product-wide Cloud lock.
7. Confirm `ci_scripts/ci_post_xcodebuild.sh` ran during the build-for-testing
   phase and produced the lint and unsigned iOS build. If Apple does not expose
   the source checkout at this hook stage, replace the hook with a separate Cloud
   BUILD action in the test workflow (an owner-side edit) instead of dropping the
   iOS coverage.

The required check keeps its existing name, so no branch-protection edit is
needed, and the release-version gate is retained. The helper pin
(`ref: 05993dd3ef90ff19d38440a49cc462f8f5ead2c3`) must be advanced deliberately
when the monitor changes.

**Live Cloud behavior is not yet verified:** this repository change prepares and
documents the cutover, but the automation session has no App Store Connect
credentials, so the Cloud test workflow, its alerts, and the post-xcodebuild hook
have not been exercised live. A green repository test is not proof that Cloud or
its alerts are active.
