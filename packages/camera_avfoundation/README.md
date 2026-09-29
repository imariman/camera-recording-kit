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

Each exact profile lists the codecs it can record. HEVC is only listed when
the camera's video output reports it among the codecs it can feed to an
`AVAssetWriter` for MP4 (when camera permission has not been granted yet, a
VideoToolbox encoder check is used instead). Call `setRecordingVideoCodec`
before controller creation to select the codec used by the next recording
configuration. Creating a camera whose output does not offer the selected codec
fails with `unsupportedRecordingProfile`, and `recordingQualityApplied` reports
the codec taken from the writer settings rather than the request.

## Front camera mirroring

Front camera frames are mirrored (`AVCaptureConnection.isVideoMirrored`), like
the system camera preview. The same connection feeds the `AVAssetWriter`, so
front camera recordings are mirrored in the saved file as well. This backend
has no API to turn mirroring off; the macOS backend offers `setMirror(false)`
and the Android backend does not mirror recordings. Flip the file in
post-processing if an unmirrored front camera recording is required.

[1]: https://pub.dev/packages/camera
[2]: https://flutter.dev/to/endorsed-federated-plugin
