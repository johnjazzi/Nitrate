# Agent Instructions

## Workflow: commit at every boundary

When the user signals that the current piece of work is finished and a new one is
starting — typically **"ok on to the next"**, **"looks good"**, **"go to next"**,
or any equivalent acknowledgement — **commit the completed work before starting
anything else.**

Rules:

1. The acknowledgement is the commit trigger. Do not wait to be asked.
2. Commit only work that is verified: tests green, generic iOS build exit 0,
   `git diff --check` clean.
3. One commit per completed task or coherent batch. Do not sweep unrelated
   in-progress work into the same commit.
4. Write an imperative subject naming the change, and use the body to record what
   changed and the verification performed.
5. Never commit a tree that fails to build or test.

This applies to mid-task boundaries too (e.g. a bug report arriving right after a
finished feature) — close out the finished work first, then investigate the new
item.

## Project notes

- XcodeGen project: `project.yml` is the source of truth; `*.xcodeproj` is
  gitignored. Run `xcodegen generate` after adding or removing source files.
- Verify with the RenderCLI test scheme (Swift Testing) and a generic iOS build.
  Xcode commands must run outside the sandbox (Metal access).
- Do not change white balance locking, the direct RGB/red-fastest LUT upload, or
  remove custom movie metadata without explicit instruction.
- Do not claim visual/colorimetric calibration from passing unit tests; the
  LUT/delivery contract is "user-declared", not "verified".

## Automated developer checks

- See `docs/development.md` for the verification commands and signing setup.
- Implementation subagents run `python3 scripts/verify.py lint` for quick feedback.
  The coordinating agent owns compiler checks and final verification; avoid
  duplicate Xcode builds across agents.
- Run `python3 scripts/verify.py check` for cached lint and incremental unsigned
  iOS compilation, and `python3 scripts/verify.py verify` at task completion for
  lint, RenderCLI tests, a generic iOS build, and `git diff --check`.
  Both commands must run outside the sandbox for Xcode/Metal access.
- `python3 scripts/verify.py watch` offers debounced lint/compiler checks while
  editing. Start it outside the sandbox only when needed; stop it before final
  verification. It does not replace the final test suite.
- Use `python3 scripts/verify.py device` for signed device builds.
  Keep automatic signing and the team in `project.yml`; routine
  verification disables signing and never changes account settings.
- The user has requested automatic builds at completion. After every iOS code
  change, run `python3 scripts/verify.py verify` and then
  `python3 scripts/verify.py device` outside the sandbox. Run the signed device
  build last so the final app artifact is signed and ready to run from Xcode.
  The coordinating agent owns both passes; implementation subagents use lint.
- Read the concise diagnostics and the indicated log before retrying a failure.
  Do not rerun an unchanged failing command or repeatedly dump full build logs.
