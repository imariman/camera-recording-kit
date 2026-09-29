# Camera Recording Kit

Camera Recording Kit is a Git-consumed Flutter camera stack for applications
that need explicit recording-profile negotiation and native quality readback.
It packages a shared `camera_recording` API with maintained Android CameraX,
iOS AVFoundation, and macOS AVFoundation backends. It is intentionally not
published on pub.dev.

## Use from Git

Keep the normal `camera` dependency required by your application, then use the
kit's packages from this repository. Pin `ref` to a reviewed tag or commit in
production.

```yaml
dependencies:
  camera: ^0.12.0+2
  camera_recording:
    git:
      url: https://github.com/imariman/camera-recording-kit.git
      path: packages/camera_recording
      ref: SAME_COMMIT

dependency_overrides:
  camera_android_camerax:
    git:
      url: https://github.com/imariman/camera-recording-kit.git
      path: packages/camera_android_camerax
      ref: SAME_COMMIT
  camera_avfoundation:
    git:
      url: https://github.com/imariman/camera-recording-kit.git
      path: packages/camera_avfoundation
      ref: SAME_COMMIT
  camera_desktop:
    git:
      url: https://github.com/imariman/camera-recording-kit.git
      path: packages/camera_desktop
      ref: SAME_COMMIT
```

Replace every `SAME_COMMIT` with the same reviewed repository commit or tag.
The overrides keep Flutter's `camera` package resolving its platform
implementations to this repository. `camera_recording` is already pinned by
its direct Git dependency; the other three names override the hosted camera
implementations selected transitively by `camera`.

## Support and quality boundary

Android, iOS, and macOS are the maintained recording-quality scope. The
quality API distinguishes requested intent, native applied format, and
finalized-file metadata. Capability lists are camera-specific; an unsupported
profile must surface a fallback or error rather than being silently accepted.

`camera_desktop` retains its upstream Linux and Windows implementations, but
they do not have parity with this repository's macOS quality extension,
native synthetic-test coverage, pause/resume timing, or stabilization support.
Treat Linux and Windows recording quality as inherited upstream behavior until
they gain equivalent validation.

See [architecture](docs/ARCHITECTURE.md), [quality and physical QA](docs/QUALITY_AND_PHYSICAL_QA.md), and [third-party notices](THIRD_PARTY_NOTICES.md).

## Validation

Run `tool/validate.sh` from the repository root. It analyzes and tests every
package sequentially. On a developer Mac it uses `mobile-slot` when available;
CI runs the same Flutter commands directly. On macOS, `tool/validate.sh` then
runs the native synthetic tests (`tool/test_macos_camera_native.py`), which
require full Xcode selected with `xcode-select`; with only the Command Line
Tools, or on another OS, it prints a skip line instead. CI runs the native
tests in a separate macOS job. Hardware acceptance remains a release gate and
is not replaced by automation.

The Android JVM (Robolectric/Mockito) unit tests of `camera_android_camerax`
are not part of `tool/validate.sh` because the package has no Gradle host of
its own. Run `tool/test_android_jvm.sh` instead; it creates a throwaway Flutter
host app with a path dependency on the package and runs
`:camera_android_camerax:testDebugUnitTest` there. It needs JDK 17 or newer
(`JAVA_HOME`) and the Android SDK. Set `ANDROID_JVM_HOST_DIR` to keep the host
app between runs. CI runs the same script in the `android-jvm` job.
