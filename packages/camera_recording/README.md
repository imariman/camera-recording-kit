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
