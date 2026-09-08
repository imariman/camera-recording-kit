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
