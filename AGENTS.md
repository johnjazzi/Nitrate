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
