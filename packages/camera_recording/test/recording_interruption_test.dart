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
    test('release() while ${paused ? 'paused' : 'recording'} delivers the '
        'finalized file and keeps the service reusable', () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      addTearDown(service.dispose);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      if (paused) await service.pauseRecording();
      final controller = gateway.factory.createdControllers.last;
      final interrupted = service.onRecordingInterrupted.first;

      await service.release();

      expect(await interrupted, isInterruptedOriginal);
      expect(gateway.stops, 1);
      expect(controller.wasDisposed, isTrue);
      expect(service.controller, isNull);
      expect(service.isRecording, isFalse);

      expect(await service.initialize(front: true), isNotNull);
      expect(service.isInitialized, isTrue);
    });
  }

  test(
    'dispose() while recording delivers the finalized file, then closes',
    () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      final controller = gateway.factory.createdControllers.last;
      final events = expectLater(
        service.onRecordingInterrupted,
        emitsInOrder([isInterruptedOriginal, emitsDone]),
      );

      await service.dispose();

      await events;
      expect(gateway.stops, 1);
      expect(controller.wasDisposed, isTrue);
    },
  );

  test(
    'a stop rejected by a pending dispose still surfaces the file',
    () async {
      final gateway = QualityFakeGateway();
      final service = serviceFor(gateway);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      final delivered = service.onRecordingInterrupted.toList();

      final disposing = service.dispose();
      expect(await service.stopRecording(), isNull);
      expect(await service.finishRecording(), isNull);
      await disposing;

      expect(await delivered, [isInterruptedOriginal]);
      expect(gateway.stops, 1);
    },
  );

  test('nothing is emitted when no recording is active', () async {
    final gateway = QualityFakeGateway();
    final service = serviceFor(gateway);
    final delivered = service.onRecordingInterrupted.toList();

    await service.initialize(front: true, recordingProfile: request);
    await service.release();
    await service.initialize(front: true, recordingProfile: request);
    expect(await service.startRecording(), isTrue);
    expect(await service.finishRecording(), isNotNull);
    await service.release();
    await service.dispose();

    expect(await delivered, isEmpty);
    expect(gateway.stops, 1);
  });

  test(
    'a failed stop still releases the controller without throwing',
    () async {
      final gateway = QualityFakeGateway()
        ..stopError = CameraException('stopFailed', 'Encoder failed');
      final service = serviceFor(gateway);
      final delivered = service.onRecordingInterrupted.toList();
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      final controller = gateway.factory.createdControllers.last;

      await service.release();

      expect(controller.wasDisposed, isTrue);
      expect(service.controller, isNull);
      await service.dispose();
      expect(await delivered, isEmpty);
    },
  );

  test(
    'legacy controllers deliver the file without capture metadata',
    () async {
      final gateway = QualityFakeGateway()..qualitySelection = false;
      final service = serviceFor(gateway);
      await service.initialize(front: true, recordingProfile: request);
      expect(await service.startRecording(), isTrue);
      final interrupted = service.onRecordingInterrupted.first;

      await service.dispose();

      final result = await interrupted;
      expect(result.file.path, '/tmp/quality-original.mp4');
      expect(result.mediaMetadata, isNull);
    },
  );
}
