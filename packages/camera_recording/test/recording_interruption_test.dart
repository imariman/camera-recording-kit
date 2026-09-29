import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera_recording/camera_recording.dart';

import 'recording_quality_selection_test.dart' show QualityFakeGateway, front;

/// A recording stopped by release()/dispose() must reach the host, not vanish.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CameraService serviceFor(QualityFakeGateway gateway) => CameraService(
    const [front],
    recordingGateway: gateway,
    capabilities: DefaultCameraPlatformCapabilities.cameraCapable,
  );

  // The front camera cannot apply 4K, so it falls back to 1080p30. The
  // interrupted result must keep that capture context, as finishRecording does.
  const request = RecordingProfile(resolution: RecordingResolution.ultraHd);
  final isInterruptedOriginal = isA<RecordingResult>()
      .having((r) => r.file.path, 'file.path', '/tmp/quality-original.mp4')
      .having((r) => r.mediaMetadata?.cameraName, 'cameraName', 'front')
      .having((r) => r.mediaMetadata?.configuredWidth, 'configuredWidth', 1920)
      .having((r) => r.mediaMetadata?.configuredFps, 'configuredFps', 30)
      .having(
        (r) => r.mediaMetadata?.fallbackReason,
        'fallbackReason',
        'unsupportedProfile',
      )
      // Not inspected: the fake inspector would report a 1250 ms duration.
      .having(
        (r) => r.mediaMetadata?.durationMilliseconds,
        'durationMilliseconds',
        isNull,
      );

  for (final paused in [false, true]) {
    test('release() while ${paused ? 'paused' : 'recording'} returns the '
        'finalized file and keeps the service reusable', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      addTearDown(service.dispose);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      if (paused) await service.pauseRecording();
      final controller = gateway.factory.createdControllers.last;

      final interrupted = await service.release();

      expect(interrupted, isInterruptedOriginal);
      expect(gateway.stops, 1);
      expect(controller.wasDisposed, isTrue);
      expect(service.controller, isNull);
      expect(service.isRecording, isFalse);

      expect(await service.initialize(front: true), isNotNull);
      expect(service.isInitialized, isTrue);
    });
  }

  test('dispose() while recording returns the finalized file, and later '
      'calls return the same result', () async {
    final gateway = QualityFakeGateway();
    final service = serviceFor(gateway);
    await service.initialize(front: true, recordingProfile: request);
    expect(await service.startRecording(), isTrue);
    final controller = gateway.factory.createdControllers.last;

    final first = await service.dispose();
    final second = await service.dispose();

    expect(first, isInterruptedOriginal);
    expect(second, same(first));
    expect(gateway.stops, 1);
    expect(controller.wasDisposed, isTrue);
  });

  test(
    'a stop rejected by a pending dispose is still returned by dispose()',
    () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);

      final disposing = service.dispose();
      expect(await service.stopRecording(), isNull);
      expect(await service.finishRecording(), isNull);

      expect(await disposing, isInterruptedOriginal);
      expect(gateway.stops, 1);
    },
  );

  test(
    'release() and dispose() return null when no recording is active',
    () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);

      await service.initialize(front: true, recordingProfile: request);
      expect(await service.release(), isNull);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      expect(await service.finishRecording(), isNotNull);
      expect(await service.release(), isNull);
      expect(await service.dispose(), isNull);
      expect(gateway.stops, 1);
    },
  );

  test(
    'a failed stop still releases the controller without throwing',
    () async {
      final gateway = QualityFakeGateway()
        ..stopError = CameraException('stopFailed', 'Encoder failed');
      final service = serviceFor(gateway);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      final controller = gateway.factory.createdControllers.last;

      expect(await service.release(), isNull);

      expect(controller.wasDisposed, isTrue);
      expect(service.controller, isNull);
      expect(await service.dispose(), isNull);
    },
  );

  test('a failed dispose does not lose the finalized file', () async {
    final gateway = QualityFakeGateway()
      ..disposeError = CameraException('disposeFailed', 'Camera vanished');
    final service = serviceFor(gateway);
    await service.initialize(front: true, recordingProfile: request);
    expect(await service.startRecording(), isTrue);

    expect(await service.release(), isInterruptedOriginal);
    expect(service.controller, isNull);
  });

  test('legacy controllers return the file without capture metadata', () async {
    final gateway = QualityFakeGateway()..qualitySelection = false;
    final service = serviceFor(gateway);
    // Legacy backends reject explicit formats, so use the automatic profile.
    await service.initialize(
      front: true,
      recordingProfile: const RecordingProfile(),
    );
    expect(await service.startRecording(), isTrue);

    final result = await service.dispose();

    expect(result?.file.path, '/tmp/quality-original.mp4');
    expect(result?.mediaMetadata, isNull);
  });
}
