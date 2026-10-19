# CI migration

## Target split

- **GitHub/Linux:** release-version enforcement and portable Python policy tests.
- **Xcode Cloud:** one macOS `RenderCLI` Test action for validation; a separate
  production `Nitrate` Archive workflow for merge-to-TestFlight delivery.
- Start with manual dispatch. Enable automatic PR/main orchestration only after
  the workflows, monitoring, and exact-commit checks have been exercised live.
- Keep the existing native GitHub requirement until its replacement has passed
  and the replacement status context has been verified. Do not leave a gap in
  required native validation.

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
6. Run the portable GitHub workflow on Ubuntu and inspect real results.
7. Register the demonstrated replacement native status context in protection,
   retain the release-version gate, then retire the GitHub macOS test job.

A new dispatch-only workflow must be present on the default branch for normal
workflow discovery. The existing dispatch-enabled `xcode.yml` path can host a
staged monitor on `dev` for the initial `--ref dev` validation without merging
untested orchestration. Read that ref's actual workflow before dispatching.

**Current live state is not verified:** the automation browser is unauthenticated,
no App Store Connect credentials are available to this session, and Cloud runs
have not been started by this migration. Repository implementation is preparation,
not proof that Cloud or its alerts are active.
