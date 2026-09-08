# Extraction validation — 2026-09-08

Source: Teleprompter PR #24, commit
`a2606eccf106cdb3b39f246cec9ddbc71cf8920d`.
Toolchain: Flutter 3.47.2, Dart 3.13.2, macOS with Xcode.

The shared service, gateway and recording models retain their executable
behavior. Application imports use compatibility exports. All imported native
production sources and the three original license files are byte-identical to
the source snapshot; changes to forks are package metadata, analyzer setup and
standalone test maintenance.

| Check | Result |
| --- | --- |
| Shared `camera_recording` Dart suite | 43 passed |
| Android CameraX Dart suite | 131 passed |
| iOS AVFoundation Dart suite | 68 passed |
| Desktop Dart suite | 31 passed |
| macOS native synthetic media XCTest suite | 17 passed |
| Teleprompter unit/widget integration suite using extracted packages | 739 passed |
| Flutter analysis of each package and Teleprompter | No issues |

Local Flutter tests ran through `mobile-slot test -- flutter test --concurrency=1 --no-pub`.
The native command was `mobile-slot run -- python3 tool/test_macos_camera_native.py`.

Two controlled mutations demonstrated regression detection: reversing profile
resolution priority failed the selection assertion; reporting a preview width
off by one failed the CameraInitializedEvent assertion. Exact source restoration
made both tests pass. The event test previously mocked an upstream use-case
binding that no longer matched the existing fork; it now observes the recording
binding and awaits the event assertion.

The obsolete upstream skills-validation test referenced absent imported tooling
and was removed; this was not camera behavior coverage. Existing generated-file
lint noise is excluded without modifying generated sources.

No physical camera, microphone, long-recording or unplug/reconnect acceptance
was performed. Synthetic media tests verify timing and processing behavior,
not image quality on actual hardware. Android JVM and iOS native SDK validation
from PR #24 were not rerun for this source-preserving extraction.
