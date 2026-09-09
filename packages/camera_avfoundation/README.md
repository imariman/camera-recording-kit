# camera\_avfoundation

The iOS implementation of [`camera`][1].

## Usage

This package is [endorsed][2], which means you can simply use `camera`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

## Recording quality inspection

`recording_quality.dart` exposes iOS-only helpers for the host app's recording
workflow: `recordingQualityCapabilities`, `recordingQualityApplied`,
`inspectRecordingMedia`, and `waitForRecordingFocus`. The capability response
contains only encoder-compatible SD/HD/FHD/UHD profiles at 30 or 60 fps. The
focus helper waits for real focus and exposure adjustments to settle for at
most two seconds and reports convergence without changing the lock modes. The
host applies both locks after a successful result; a timeout or unsupported lock
returns `false` so the host can retain continuous automatic focus and exposure.

Each exact profile includes encoder-validated H.264/HEVC support.
Call `setRecordingVideoCodec` before controller creation to select the
codec used by the next recording configuration.

[1]: https://pub.dev/packages/camera
[2]: https://flutter.dev/to/endorsed-federated-plugin
