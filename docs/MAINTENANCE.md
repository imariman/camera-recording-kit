# Maintaining the Git-only camera stack

The imported baseline is Teleprompter PR #24 at
`a2606eccf106cdb3b39f246cec9ddbc71cf8920d`. Upstream versions and licenses are
listed in [third-party notices](../THIRD_PARTY_NOTICES.md). This repository
contains maintained source copies from multiple upstream repositories; it is
not a single GitHub fork network. Native channel names and plugin identifiers
are intentionally unchanged so applications keep using the `camera` API.

## Updating a backend

1. Record the selected upstream release/tag and exact upstream commit.
2. Update only that platform package and preserve its complete license and
   copyright notices. Reapply the smallest local quality/recording patches.
3. Preserve capability discovery, applied-format readback, focus convergence,
   stabilization confirmation, media inspection and macOS timeline handling.
   Compare the native patch separately from generated source churn.
4. Regenerate Pigeon and mocks only if their inputs changed, using the
   corresponding package toolchain. Run `bash tool/validate.sh` and the relevant
   native compilation/tests. Local Macs use `mobile-slot` guards.
5. Complete the affected [physical-device checks](QUALITY_AND_PHYSICAL_QA.md).
   Synthetic media and Dart tests cannot establish device camera quality.
6. Test an application with all four packages overridden to the same checkout.
   After pushing the reviewed change, pin that commit for all four Git package
   entries in the application and regenerate its lockfile without local overrides.

All packages set `publish_to: none`; no pub.dev release is part of this workflow.
The three fork version numbers track their imported baselines for compatibility;
Git commit hashes identify the exact maintained revision. The shared API starts
at `camera_recording` 0.1.0. Future public package naming and hosted dependency
registration should be a separate change rather than bundled into an upstream update.
