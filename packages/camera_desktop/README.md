<h1 align="center">camera_desktop</h1>

<p align="center">
<a href="https://flutter.dev"><img src="https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter" alt="Platform"></a>
<a href="https://dart.dev"><img src="https://img.shields.io/badge/language-Dart-blue" alt="Language: Dart"></a>
<br>
<a href="https://pub.dev/packages/camera_desktop"><img src="https://img.shields.io/pub/v/camera_desktop?label=pub.dev&labelColor=333940&logo=dart" alt="Pub Version"></a>
<a href="https://pub.dev/packages/camera_desktop/score"><img src="https://img.shields.io/pub/points/camera_desktop?color=2E8B57&label=pub%20points" alt="pub points"></a>
<a href="https://github.com/hugocornellier/camera_desktop/actions/workflows/ci.yml"><img src="https://github.com/hugocornellier/camera_desktop/actions/workflows/ci.yml/badge.svg" alt="Flutter CI"></a>
<a href="https://github.com/hugocornellier/camera_desktop/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-007A88.svg" alt="License"></a>
</p>

A Flutter camera plugin for desktop platforms. Implements
[`camera_platform_interface`](https://pub.dev/packages/camera_platform_interface)
so it works seamlessly with the standard
[`camera`](https://pub.dev/packages/camera) package and `CameraController`.

## Platform Support

| Platform | Backend | Status |
|----------|---------|--------|
| **Linux** | GStreamer + V4L2 | Included |
| **macOS** | AVFoundation | Included |
| **Windows** | Media Foundation | Included |

## Installation

Add `camera_desktop` alongside `camera` in your `pubspec.yaml`:

```yaml
dependencies:
  camera: ^0.11.0
  camera_desktop: ^1.2.1
```

That's it. All three desktop platforms are covered, no additional packages needed.

## Usage

Use the standard `camera` package API:

```dart
import 'package:camera/camera.dart';

final cameras = await availableCameras();
final controller = CameraController(cameras.first, ResolutionPreset.high);
await controller.initialize();

// Preview
CameraPreview(controller);

// Capture
final file = await controller.takePicture();

// Record
await controller.startVideoRecording();
final video = await controller.stopVideoRecording();
```

### Advanced Settings

`CameraController` (camera 0.11.x+) accepts optional `fps`, `videoBitrate`, and
`audioBitrate` parameters at construction time:

```dart
final controller = CameraController(
  cameras.first,
  ResolutionPreset.veryHigh,
  enableAudio: true,
  fps: 30,
  videoBitrate: 5000000,   // 5 Mbps
  audioBitrate: 128000,    // 128 kbps
);
```

These settings are applied during `initialize()`. To change them you must
`dispose()` the controller and create a new one, see [Limitations](#limitations).

## Platform-Specific Setup

### Linux

Install GStreamer development libraries:

```bash
# Ubuntu/Debian
sudo apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good

# Fedora
sudo dnf install gstreamer1-devel gstreamer1-plugins-base-devel gstreamer1-plugins-good

# Arch
sudo pacman -S gstreamer gst-plugins-base gst-plugins-good
```

### macOS

Add camera and microphone usage descriptions to your `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access for video recording.</string>
```

For sandboxed apps, add to your entitlements:

```xml
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

#### Strict macOS recording quality extension

This vendored package adds a macOS-only quality channel for applications that
must verify the actual capture profile before recording:

```dart
import 'package:camera_desktop/recording_quality.dart';

final capabilities = await recordingQualityCapabilities(camera.name);
final applied = await recordingQualityApplied(controller.cameraId);
final metadata = await inspectRecordingMedia(recording.path);
final settled = await waitForRecordingFocus(controller.cameraId);
```

The channel is `dev.teleprompter/camera_desktop_recording_quality`. Capability
discovery resolves the selected AVFoundation `uniqueID`, identifies internal,
external, and Continuity cameras, and returns only H.264-compatible SDR
profiles: safe 640x480p30 plus 720p, 1080p, and 2160p at supported 30/60 FPS.
No profile above 4K is advertised or selected.

`ResolutionPreset.medium`, `high`, `veryHigh`, and `ultraHigh` map to exact
480p, 720p, 1080p, and 2160p formats. An explicit FPS must be 30 or 60. If the
camera and encoder cannot apply that exact pair, initialization fails with
`unsupportedRecordingProfile`; AVFoundation is not allowed to silently choose
a different format. Initialization also verifies the first capture sample's
dimensions before reporting the camera ready. When audio is enabled, missing
microphone permission or capture support fails initialization rather than
creating a silent recording.

`recordingQualityApplied` reports first-sample dimensions and the configured
active-format dimensions/frame duration. Final MP4 inspection reports track
dimensions, duration, nominal or measured FPS, codec, estimated bitrate,
rotation, MIME type, and file size when each value is available. Inspection
reads container metadata and compressed samples only; it does not transfer
frames through Dart or re-encode the recording.

Focus/exposure automatic and locked modes and normalized points are forwarded
to AVFoundation when the selected camera reports support. The bounded focus
wait observes convergence for at most two seconds and never changes a lock
mode selected by Dart.

macOS recording pause/resume removes paused time from both audio and video
using the capture session clock, preserving one synchronized MP4. Stopping
while paused finalizes that file. Other desktop platforms retain their existing
unsupported pause behavior.

`getSupportedVideoStabilizationModes` exposes `off` and, at up to 1080p30,
`level1`. On macOS, level 1 is software translation correction using Vision and
Core Image, with a fixed 6% edge crop; 4K and 60 FPS expose only `off`. The mode
setter verifies a processed capture frame before returning. Applied quality
readback includes `stabilizationEnabled`, `stabilizationAlgorithm`,
`stabilizationCropInsetFraction` and any latest `stabilizationFailure`.
Preview, recording and point-of-interest mapping share the same crop. Motion
history resets on resume and private buffers are bounded. Software stabilization
is disabled by default and does not promise optical or rotational correction.

Call `setMirror(cameraId, false)` after initialization and before recording to
keep the captured file unmirrored.

### Windows

No additional setup required.

## Features

| Feature | Linux | macOS | Windows |
|---------|-------|-------|---------|
| Camera enumeration | Yes | Yes | Yes |
| Live preview | Yes | Yes | Yes |
| Photo capture | Yes | Yes | Yes |
| Video recording | Yes | Yes | Yes |
| Image streaming | Yes | Yes | No |
| Audio recording | Yes | Yes | Yes |
| Recording pause/resume | No | Yes | No |
| Software stabilization | No | Up to 1080p30 | No |
| Resolution presets | Yes | Yes | Yes |
| Custom FPS | Yes | Yes | Yes |
| Video bitrate control | Yes | Yes | Yes |
| Audio bitrate control | Yes | Yes | Yes |
| Mirror control | Yes | Yes | No (handled in Flutter) |

## Mirror / Flip Behavior

On **macOS** and **Linux**, the preview frames are mirrored at the native capture
level (like a webcam selfie view), so `buildPreview()` returns the texture as-is.
The mirror state can be toggled at runtime via `setMirror()`:

```dart
import 'package:camera_desktop/camera_desktop.dart';

// Toggle mirror at runtime (macOS & Linux only)
final plugin = CameraDesktopPlugin();
await plugin.setMirror(cameraId, false); // disable mirror
await plugin.setMirror(cameraId, true);  // re-enable mirror
```

On **Windows**, the native backend does not mirror, so the example app wraps the
preview in a horizontal `Transform` in Flutter:

```dart
if (Platform.isWindows) {
  return Transform(
    alignment: Alignment.center,
    transform: Matrix4.diagonal3Values(-1, 1, 1),
    child: Texture(textureId: textureId),
  );
}
```

The same applies to video playback. Recorded files from macOS/Linux are already
mirrored, while Windows recordings need a Flutter-side flip if you want a
mirror-style playback.

## Platform Capabilities

Query what the current platform supports at runtime:

```dart
import 'package:camera_desktop/camera_desktop.dart';

final caps = await CameraDesktopPlugin().getPlatformCapabilities();
// caps['supportsMirrorControl'] == true  (macOS & Linux)
// caps['supportsVideoFpsControl'] == true
// caps['supportsVideoBitrateControl'] == true
// caps['supportsAudioBitrateControl'] == true
```

This is useful when building UIs that conditionally expose controls based on the
running platform.

## Limitations

Desktop cameras generally do not support mobile-oriented features:

- Flash/torch control
- Exposure/focus point selection on Linux and Windows; macOS checks each camera
- Zoom (beyond 1.0x)
- Device orientation changes
- Pause/resume video recording on Linux and Windows

These methods either no-op or throw `CameraException` as appropriate.

`fps`, `videoBitrate`, and `audioBitrate` are applied at initialization and cannot
be changed on a running controller. To update them, `dispose()` the controller and
create a new one with the desired settings.
