# Development verification

Run `python3 scripts/verify.py` for the routine check. It regenerates the Xcode
project, then incrementally compiles the app for a generic iOS destination with
code signing disabled. This is the usual feedback loop for implementation work.

The available modes are:

```sh
python3 scripts/verify.py lint    # SwiftLint correctness checks only
python3 scripts/verify.py check   # default: unsigned generic iOS compile
python3 scripts/verify.py verify  # lint, RenderCLI tests, iOS compile, diff check
python3 scripts/verify.py device  # signed generic iOS build
python3 scripts/verify.py watch   # debounced lint and compiler checks on edits
```

Full output, lock files, and shared derived data live under the ignored
`build/verification/` directory. Failures print at most the last 30 log lines
and the path to the complete log. A command runs once per invocation; failed
checks are not retried. The build lock prevents concurrent workflows from
sharing derived data. Lint has its own lock because Xcode also runs it during
the app target's build phase.

SwiftLint must be installed and available on `PATH`. The build phase adds common
Homebrew locations to `PATH`, runs the cached strict linter, and fails the iOS
build when a configured correctness rule fails. It does not rewrite or format
source files.

Xcode commands require execution outside the agent sandbox because the build
uses Metal tooling. This script does not provide live editor diagnostics: there
is no connected SourceKit-LSP tool in this development session.

The signed device mode retains the automatic signing team configured in
`project.yml` and passes `-allowProvisioningUpdates`. Xcode must already have an
Apple developer account signed in and access to that team; initial account,
certificate, and provisioning setup may still require Xcode's normal prompts.
The mode builds only and does not install the app on a device.

Implementation agents should run lint for quick feedback and use the routine
check when compiler feedback is needed. Full tests and the generic build are
costlier; the coordinating agent owns that complete verification pass to avoid
duplicating build time.

Watch mode checks file metadata once per second and caches content hashes. It
waits for one quiet second before checking, ignores identical saves, and picks
up edits made during a build on its next pass. Stop it with Control-C before
running full verification. It is an optional foreground command, not a service
installed on your Mac.
