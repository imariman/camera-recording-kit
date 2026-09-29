# Imported upstream tooling

The upstream `packages/camera_android_camerax` workflow guidance refers to
`.agents/skills` directories, including `check-readiness` and pre-push tooling,
that were not included in the Teleprompter PR #24 fork snapshot. The package's
`AGENTS.md` therefore points to this repository's `tool/validate.sh` and
`tool/test_android_jvm.sh` instead of those skills, and `skills/README.md` is
retained only as imported upstream text. The package does not run the upstream
`dart_skills_lint` validation or its custom publishing-prevention test.

This does not change package runtime behavior, native code, or its Flutter and
CameraX test coverage. Repository validation uses `tool/validate.sh`, the
package's retained Dart tests, and the JVM unit tests run by
`tool/test_android_jvm.sh`.
