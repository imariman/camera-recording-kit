# camera\_android\_camerax

The Android implementation of [`camera`][1] built with the [CameraX library][2].

*Note*: If any of [the limitations](#limitations) prevent you from using
`camera_android_camerax` or if you run into any problems, please report
fork-specific issues in the
[Camera Recording Kit issue tracker](https://github.com/imariman/camera-recording-kit/issues)
and upstream CameraX plugin issues under [`flutter/flutter`][5] with `[camerax]`
in the title.
You may also opt back into the [`camera_android`][9] implementation if you need.

## Usage

This is the Camera Recording Kit fork of the package. It is consumed from Git
and is not published on pub.dev. Upstream `camera_android_camerax` is
[endorsed][3] by `camera`, so `camera` alone resolves the hosted upstream
package, which lacks this fork's recording quality extension. Applications
must add a `dependency_overrides` entry that points `camera_android_camerax`
at this repository, pinned to the same commit as the kit's other packages:

```yaml
dependency_overrides:
  camera_android_camerax:
    git:
      url: https://github.com/imariman/camera-recording-kit.git
      path: packages/camera_android_camerax
      ref: SAME_COMMIT
```

See the [repository README](../../README.md#use-from-git) for the complete
`pubspec.yaml` setup. This fork requires Flutter 3.44 or newer (Dart 3.12).

If you `import` this package to use its APIs directly, such as
`recording_quality.dart`, also list it under `dependencies` with the same Git
source.

### Recording quality extension

Import `package:camera_android_camerax/recording_quality.dart` to query the
Android recording backend directly:

* `recordingQualityCapabilities(cameraName)` returns only 30/60 FPS SDR
  combinations verified against CameraX recording qualities, a fixed
  `[fps, fps]` camera frame-rate range (the same range the preview requests and
  `recordingQualityApplied` requires; a variable range such as `[15, 60]` is not
  enough), per-size sensor duration, an H.264 CameraX encoder profile, and the
  size/rate limits of an installed hardware H.264 encoder (software encoders
  count only on devices without one). Capabilities are built off the main
  thread. It also reports native focus-lock and exposure-lock support for that
  camera name.
* `recordingQualityApplied(cameraId)` reads the resolution from the bound
  `VideoCapture`, and the frame rate and stabilization state from the latest
  Camera2 `CaptureResult` (`CONTROL_AE_TARGET_FPS_RANGE` and
  `CONTROL_VIDEO_STABILIZATION_MODE`), so it reports what the camera applied
  rather than what was requested. It waits up to two seconds for capture
  results to reflect the request. If CameraX did not apply a recording profile,
  or the camera does not report a fixed frame rate, it throws a
  `PlatformException` with code `unsupportedRecordingProfile`.
* `waitForRecordingFocus(cameraId)` observes the active metering target for up
  to two seconds and succeeds only when both AF and AE capture-result states
  converge. It does not submit a new metering request or lock focus; callers
  may apply their requested lock only after convergence succeeds.
* `inspectRecordingMedia(path)` reads finalized MP4 container and track
  metadata without decoding video frames. `mimeType` is the container type
  (`video/mp4`), as on iOS and macOS; `codec` comes from the video track.

Each exact format advertises its codec support. CameraX advertises H.264 only
because its public Recorder API cannot deterministically select HEVC;
`setRecordingVideoCodec('hevc')` therefore reports `unsupportedVideoCodec`.

Initialization binds `Preview` and `VideoCapture` together, and both stay bound
after a recording stops, so the next recording starts without reconfiguring the
camera session and the readback above keeps working between recordings. Still
capture and image analysis remain available and are bound lazily when requested. Recording
quality selection uses an exact CameraX `QualitySelector`; callers should retry
their own approved lower profile after `unsupportedRecordingProfile` instead of
assuming a fallback was applied. Binding reports `unsupportedRecordingProfile`
only when CameraX rejects the use-case configuration (surface combination,
resolution, quality or frame rate); other failures, such as a camera that is no
longer available, are reported as errors.

## Limitations

### 240p resolution configuration for video recording

240p resolution configuration for video recording is unsupported by CameraX, and thus,
the plugin will fall back to target 480p (`ResolutionPreset.medium`) if configured with
`ResolutionPreset.low`.

### Setting stream options for video capture

Calling `startVideoCapturing` with `VideoCaptureOptions` configured with
`streamOptions` is currently unsupported do to
limitations of the platform interface,
and thus that parameter will silently be ignored.

## What requires Android permissions

### Writing to external storage to save image files

In order to save captured images and videos to files on older Android versions, CameraX
requires specifying the `WRITE_EXTERNAL_STORAGE` permission (see [the CameraX documentation][10]).
The plugin already declares it for Android 9 (API level 28) and below
(`android:maxSdkVersion="28"`), so no further action is required on your end.

To understand the privacy impact of specifying the `WRITE_EXTERNAL_STORAGE` permission, see the
[`WRITE_EXTERNAL_STORAGE` documentation][11]. We have seen apps also have the [`READ_EXTERNAL_STORAGE`][13]
permission automatically added to the merged Android manifest; it appears to be implied from
`WRITE_EXTERNAL_STORAGE`. If you do not want the `READ_EXTERNAL_STORAGE` permission to be included
in the merged Android manifest of your app, then take the following steps to remove it:

1. Ensure that your app nor any of the plugins that it depends on require the `READ_EXTERNAL_STORAGE` permission.
2. Add the following to your app's `your_app/android/app/src/main/AndroidManifest.xml`:

```xml
  <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    tools:node="remove" />
```

### Notes on video capture

#### Setting description while recording
To avoid cancelling any active recording when calling `setDescriptionWhileRecording`,
you must start the recording with `startVideoCapturing` with `enablePersistentRecording` set to `true`.

### Notes on image streaming

#### Allowing image streaming in the background

As of Android 14, to allow for background image streaming, you will need to specify the foreground
[`TYPE_CAMERA`][12] foreground service permission in your app's manifest. Specifically, in
`your_app/android/app/src/main/AndroidManifest.xml` add the following:

```xml
<manifest ...>
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
  ...
</manifest>
```

#### Configuring NV21 image format

If you initialize a `CameraController` with `ImageFormatGroup.nv21`, then streamed images will
still have the `ImageFormatGroup.yuv420` format, but their image data will be formatted in NV21.
See https://developer.android.com/reference/kotlin/androidx/camera/core/ImageAnalysis#OUTPUT_IMAGE_FORMAT_NV21().

## Contributing

For more information on contributing to this plugin, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

<!-- Links -->

[1]: https://pub.dev/packages/camera
[2]: https://developer.android.com/training/camerax
[3]: https://flutter.dev/to/endorsed-federated-plugin
[4]: https://pub.dev/packages/camera_android
[5]: https://github.com/flutter/flutter/issues/new/choose
[6]: https://developer.android.com/media/camera/camerax/architecture#combine-use-cases
[7]: https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#INFO_SUPPORTED_HARDWARE_LEVEL_3
[8]: https://developer.android.com/reference/android/hardware/camera2/CameraMetadata#INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED
[9]: https://pub.dev/packages/camera_android#usage
[10]: https://developer.android.com/media/camera/camerax/architecture#permissions
[11]: https://developer.android.com/reference/android/Manifest.permission#WRITE_EXTERNAL_STORAGE
[12]: https://developer.android.com/reference/android/Manifest.permission#FOREGROUND_SERVICE_CAMERA
[13]: https://developer.android.com/reference/android/Manifest.permission#READ_EXTERNAL_STORAGE
[148013]: https://github.com/flutter/flutter/issues/148013
