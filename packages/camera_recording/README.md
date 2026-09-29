# camera_recording

Shared recording profiles, capability negotiation, metadata inspection, and
serialized `CameraController` lifecycle management for the repository's
Android, iOS, and macOS camera forks.

```dart
import 'package:camera/camera.dart';
import 'package:camera_recording/camera_recording.dart';

Future<XFile?> recordClip() async {
  final service = CameraService(await availableCameras());
  try {
    await service.initialize(
      front: true,
      recordingProfile: const RecordingProfile(),
    );
    if (!await service.startRecording()) return null;
    return (await service.finishRecording())?.file;
  } finally {
    await service.dispose();
  }
}
```

This package is consumed from Git and is not published to pub.dev.

## Recording controls

`RecordingProfile` supports explicit 480p, 720p, 1080p, and 4K targets,
30/60 FPS, audio enablement, bitrate presets, H.264/HEVC preference, and
capture-orientation locking. `CameraService` also exposes capability-driven
zoom and exposure-compensation ranges. Exact formats advertise their codec
support, so callers can hide combinations the selected camera cannot apply.

HEVC is selectable only when the native backend validates it for the exact
camera format. CameraX currently advertises H.264 because its public Recorder
API does not provide deterministic codec selection. If an HEVC configuration
is rejected, H.264 is retried at the same resolution and frame rate before the
service falls back to a smaller format. Finalized AVC/HEVC codec identifiers
are normalized to `h264`/`hevc` in `RecordedMediaMetadata`.

`RecordingProfile.quality` is a coarse intent for backends without quality
selection only (see below). On Android, iOS, and macOS the explicit resolution,
frame rate, bitrate, and codec select the format; changing only `quality` there
updates `recordingProfile` without restarting the preview.

## Requested, applied, and inspected profiles

`recordingProfile` is what the caller asked for and is never rewritten.
`appliedProfile` is the format verified by native readback on the active
camera, and `RecordingResult.mediaMetadata` describes the finalized file. Both
carry a `fallbackReason` (see `RecordingFallbackReason`) whenever they differ
from the request:

| Reason | Meaning |
| --- | --- |
| null | The request was applied exactly, including an explicit 480p target. |
| `configurationRejected` | The best candidate was rejected by the camera and a later one was applied. |
| `unsupportedProfile` | The lens does not offer the requested resolution, frame rate, or codec. |
| `encodedMismatch` | Configuration was exact, but the finalized file differs from it. |

Explicit resolutions are resolution-first: a lens never records larger than
the target while it has a format at or below it. When it has none (for example
a remembered 480p profile on a lens whose smallest format is 720p), the closest
larger format is applied with `unsupportedProfile`, so switching to that lens
still works. With `RecordingResolution.automatic` the best format of the lens
is used whatever its size, and the requested frame rate comes first: `fps: 60`
applies 1080p60 rather than 2160p30 when both exist.

`encodedMismatch` never replaces a configuration-time reason. A frame rate
that the inspector reports as `measured` is compared with a 10% tolerance,
because the average over a real file includes edge frames, drops, and longer
low-light exposures; a `nominal` rate keeps a one-frame tolerance.

## Camera selection and lifecycle

`CameraService` serializes camera operations in one queue. `initialize()` uses
a `preferredName` that names an available camera first, then the camera
selected earlier in the service's lifetime (so `release()` followed by
`initialize()` resumes on the camera the user switched to), and only then the
`front` flag. `switchCamera()` resolves the next camera when its queued turn
runs, so rapid repeated calls advance one camera each.

Stabilization changes made during a recording do not touch the live stream:
`setVideoStabilizationEnabled` returns false and the preference is applied
once the recording stops. `appliedProfile.stabilizationEnabled` reports only
what native readback confirmed.

`appliedProfile`, `recordingCapabilities`, and the zoom and exposure ranges
describe the active controller and are cleared when it is released, including
after a camera switch whose recovery also failed. A failed `dispose` of the
old controller does not prevent the switch or its recovery.

`finishRecording()` serializes only the stop; the best-effort inspection of
the finalized file runs outside the queue, so a following `release()` or
`dispose()` is not delayed by it.

A stop the platform rejects (for example an Android recording finalized
without a usable file) is rethrown by `stopRecording()` and
`finishRecording()`. The native recording has ended by then, so the service
stops reporting it as active: `startRecording()`, `switchCamera()` and
`applyRecordingProfile()` work again without releasing the camera.

## Backends without quality selection

With a custom `controllerFactory`, or on hosts without a quality backend such
as Windows and Linux, `supportsQualitySelection` is false. These backends honor
`recordAudio`, `lockOrientation`, and `quality` (mapped to a `ResolutionPreset`
by `CameraService.resolutionPresetFor`), and report no `appliedProfile`
because nothing can be read back. A profile with an explicit resolution, a
60 FPS rate, a bitrate preset, or HEVC is rejected with a `CameraException`
coded `unsupportedRecordingProfile` instead of being silently ignored; an
already running preview is kept.
