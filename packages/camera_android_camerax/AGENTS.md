# Agent Guide for camera_android_camerax

## Core Workflows

- **Regenerate Code**:
  - Pigeon (`dart run pigeon --input pigeons/camerax_library.dart`): Run after
    modifying `pigeons/camerax_library.dart`.
  - Mocks (`dart run build_runner build -d`): Run after modifying mocked
    classes or adding new mocks.
- **Verify Tests**: All tests must pass before landing. Add or update tests for
  any new logic. From the repository root, run `bash tool/validate.sh` (Dart
  analysis and tests of every package) and `bash tool/test_android_jvm.sh`
  (the Java/Robolectric unit tests of this package; needs JDK 17 or newer and
  the Android SDK).

The upstream `.agents/skills` directories (readiness, pre-push and review
skills) were not imported into this repository; see
[`docs/UPSTREAM_LIMITATIONS.md`](../../docs/UPSTREAM_LIMITATIONS.md).

## Agent Guidelines

- Technically verify review feedback before implementing suggestions,
  especially if feedback seems technically questionable.
- Plan complex features before writing code.
- Maintain high test coverage for new Dart and Java logic.
- Avoid duplicating constant strings; reuse existing ones from adjacent code.
- **CRITICAL**: When spawning subagents, NEVER provide absolute file paths in prompts. ALWAYS use relative paths. Passing absolute paths breaks `Workspace: branch` isolation and causes state bleed into the active workspace.
