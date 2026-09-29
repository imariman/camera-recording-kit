import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera_recording/camera_recording.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platforms = [
    (
      backend: RecordingBackend.android,
      channel: 'plugins.flutter.io/camera_android_camerax/recording_quality',
    ),
    (
      backend: RecordingBackend.ios,
      channel: 'dev.teleprompter/recording_quality',
    ),
    (
      backend: RecordingBackend.macos,
      channel: 'dev.teleprompter/camera_desktop_recording_quality',
    ),
  ];

  for (final platform in platforms) {
    test(
      '${platform.backend.name} routes quality inspection to its own backend',
      () async {
        final gateway = RecordingGateway(backend: platform.backend);
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final other in platforms) {
          messenger.setMockMethodCallHandler(MethodChannel(other.channel), (
            call,
          ) async {
            expect(
              other.backend,
              platform.backend,
              reason: 'Camera identifiers must never cross platform backends.',
            );
            calls.add(call);
            return switch (call.method) {
              'recordingQualityCapabilities' => {
                'profiles': [
                  {'width': 3840, 'height': 2160, 'fps': 60},
                ],
                'supportsFocusLock': true,
                'supportsExposureLock': true,
              },
              'recordingQualityApplied' => {
                'width': 3840,
                'height': 2160,
                'fps': 60,
                'stabilizationEnabled': false,
              },
              'inspectRecordingMedia' => {
                'width': 1920,
                'height': 1080,
                'durationMilliseconds': 1234,
                'fps': 29.97,
                'fpsSource': 'nominal',
              },
              'waitForRecordingFocus' => false,
              _ => throw StateError('Unexpected recording API: ${call.method}'),
            };
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              MethodChannel(other.channel),
              null,
            ),
          );
        }

        expect(gateway.supportsQualitySelection, isTrue);
        final capabilities = await gateway.capabilities('external-camera-id');
        expect(capabilities.profiles.single.shortSide, 2160);
        expect(capabilities.supportsFocusLock, isTrue);
        final applied = await gateway.applied(42);
        expect(applied['fps'], 60);
        final media = await gateway.inspect('/tmp/finalized-original.mp4');
        expect(media?.width, 1920);
        expect(media?.durationMilliseconds, 1234);
        expect(media?.fps, 29.97);
        expect(media?.fpsSource, 'nominal');
        expect(await gateway.waitForFocus(42), isFalse);
        expect(calls.map((call) => call.arguments), [
          {'cameraName': 'external-camera-id'},
          {'cameraId': 42},
          {'path': '/tmp/finalized-original.mp4'},
          {'cameraId': 42},
        ]);
      },
    );
  }

  test(
    'unsupported hosts expose no fabricated camera or media facts',
    () async {
      const gateway = RecordingGateway(backend: RecordingBackend.unsupported);
      expect(gateway.supportsQualitySelection, isFalse);
      expect((await gateway.capabilities('camera')).profiles, isEmpty);
      expect(await gateway.applied(1), isEmpty);
      expect(await gateway.inspect('/tmp/original.mp4'), isNull);
      expect(await gateway.waitForFocus(1), isFalse);
    },
  );

  const camera = CameraDescription(
    name: 'camera',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );

  for (final platform in platforms) {
    for (final codec in RecordingVideoCodec.values) {
      test(
        '${platform.backend.name} routes ${codec.name} codec selection to its '
        'own backend before creating the controller',
        () async {
          final gateway = RecordingGateway(backend: platform.backend);
          final calls = <(String, MethodCall)>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final other in platforms) {
            messenger.setMockMethodCallHandler(MethodChannel(other.channel), (
              call,
            ) async {
              calls.add((other.channel, call));
              return null;
            });
            addTearDown(
              () => messenger.setMockMethodCallHandler(
                MethodChannel(other.channel),
                null,
              ),
            );
          }

          // No camera plugin is registered in unit tests, so controller
          // initialization fails after the codec has been selected.
          await expectLater(
            gateway.createInitializedController(
              description: camera,
              preset: ResolutionPreset.veryHigh,
              enableAudio: false,
              videoCodec: codec,
            ),
            throwsA(anything),
          );

          expect(calls, hasLength(1));
          expect(calls.single.$1, platform.channel);
          expect(calls.single.$2.method, 'setRecordingVideoCodec');
          expect(calls.single.$2.arguments, {'codec': codec.name});
        },
      );
    }
  }

  test('unsupported hosts refuse HEVC before creating a controller', () async {
    const gateway = RecordingGateway(backend: RecordingBackend.unsupported);
    await expectLater(
      gateway.createInitializedController(
        description: camera,
        preset: ResolutionPreset.max,
        enableAudio: false,
        videoCodec: RecordingVideoCodec.hevc,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('macOS camera access errors retain their native error code', () async {
    const gateway = RecordingGateway(backend: RecordingBackend.macos);
    const channel = MethodChannel(
      'dev.teleprompter/camera_desktop_recording_quality',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'cameraNotBound',
        message: 'Camera was disconnected.',
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await expectLater(
      gateway.applied(9),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'cameraNotBound',
        ),
      ),
    );
  });
}
