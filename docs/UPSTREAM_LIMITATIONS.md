# Imported upstream tooling

`packages/camera_android_camerax/AGENTS.md` and `skills/README.md` retain
the imported upstream workflow guidance. Their referenced `.agents/skills` directories,
including `check-readiness` and pre-push tooling, were not included in the
Teleprompter PR #24 fork snapshot. The package therefore does not run the
upstream `dart_skills_lint` validation or its custom publishing-prevention test.

This does not change package runtime behavior, native code, or its Flutter and
CameraX test coverage. Repository validation uses `tool/validate.sh` and the
package's retained Dart tests.
