import 'dart:io';
import 'dart:math';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_desktop/src/image_stream_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraDesktopPlugin', () {
    late CameraDesktopPlugin plugin;
    late MethodChannel channel;
    final List<MethodCall> log = <MethodCall>[];

    setUp(() {
      channel = const MethodChannel('plugins.flutter.io/camera_desktop');
      plugin = CameraDesktopPlugin(channel: channel);
      log.clear();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            log.add(call);
            switch (call.method) {
              case 'availableCameras':
                return <Map<String, dynamic>>[
                  {
                    'name': 'Test Camera (/dev/video0)',
                    'lensDirection': 2,
                    'sensorOrientation': 0,
                  },
                ];
              case 'create':
                return {'cameraId': 1, 'textureId': 42};
              case 'initialize':
                return {'previewWidth': 1280.0, 'previewHeight': 720.0};
              case 'takePicture':
                return '/tmp/test.jpg';
              case 'startVideoRecording':
              case 'pauseVideoRecording':
              case 'resumeVideoRecording':
                return null;
              case 'stopVideoRecording':
                return {'path': '/tmp/test_video.mp4', 'framesDropped': 0};
              case 'startImageStream':
              case 'stopImageStream':
              case 'dispose':
              case 'pausePreview':
              case 'resumePreview':
                return null;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('registerWith sets CameraPlatform.instance', () {
      CameraDesktopPlugin.registerWith();
      expect(CameraPlatform.instance, isA<CameraDesktopPlugin>());
    });

    test('availableCameras returns camera list', () async {
      final cameras = await plugin.availableCameras();
      expect(cameras, hasLength(1));
      expect(cameras.first.name, contains('Test Camera'));
      expect(cameras.first.lensDirection, CameraLensDirection.external);
    });

    test('createCameraWithSettings returns cameraId', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      expect(cameraId, 1);
      expect(log.last.method, 'create');
    });

    test('initializeCamera fires CameraInitializedEvent', () async {
      // Create first so textureId mapping exists.
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      // Listen for the initialized event.
      final eventFuture = plugin.onCameraInitialized(cameraId).first;
      await plugin.initializeCamera(cameraId);
      final event = await eventFuture;

      expect(event.cameraId, cameraId);
      expect(event.previewWidth, 1280.0);
      expect(event.previewHeight, 720.0);
    });

    test('buildPreview returns Texture widget', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      final widget = plugin.buildPreview(cameraId);
      expect(widget, isA<Texture>());
    });

    test('takePicture returns XFile', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.initializeCamera(cameraId);

      final file = await plugin.takePicture(cameraId);
      expect(file.path, '/tmp/test.jpg');
    });

    test('dispose calls native dispose', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.dispose(cameraId);
      expect(log.last.method, 'dispose');
    });

    test('startVideoRecording calls native method', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.initializeCamera(cameraId);
      await plugin.startVideoRecording(cameraId);
      expect(log.last.method, 'startVideoRecording');
    });

    test('stopVideoRecording returns XFile', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.initializeCamera(cameraId);
      await plugin.startVideoRecording(cameraId);
      final file = await plugin.stopVideoRecording(cameraId);
      expect(file.path, '/tmp/test_video.mp4');
    });

    test('supportsImageStreaming returns true', () {
      expect(plugin.supportsImageStreaming(), isTrue);
    });

    test('onStreamedFrameAvailable starts and stops stream', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      final stream = plugin.onStreamedFrameAvailable(cameraId);
      final subscription = stream.listen((_) {});
      // Starting the stream should have called startImageStream.
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'startImageStream');

      await subscription.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'stopImageStream');
    });

    test('setFlashMode off is no-op, others throw', () async {
      // FlashMode.off is silently accepted.
      await plugin.setFlashMode(1, FlashMode.off);
      // Non-off flash modes throw.
      expect(
        () => plugin.setFlashMode(1, FlashMode.torch),
        throwsA(isA<CameraException>()),
      );
    });

    test(
      'setExposureMode delegates on macOS and preserves other backends',
      () async {
        await plugin.setExposureMode(1, ExposureMode.auto);
        if (Platform.isMacOS) {
          expect(log.last.method, 'setExposureMode');
          expect(log.last.arguments, <String, dynamic>{
            'cameraId': 1,
            'mode': ExposureMode.auto.index,
          });
          await plugin.setExposureMode(1, ExposureMode.locked);
          expect(log.last.arguments, <String, dynamic>{
            'cameraId': 1,
            'mode': ExposureMode.locked.index,
          });
        } else {
          expect(
            () => plugin.setExposureMode(1, ExposureMode.locked),
            throwsA(isA<CameraException>()),
          );
        }
      },
    );

    test(
      'setFocusMode delegates on macOS and preserves other backends',
      () async {
        await plugin.setFocusMode(1, FocusMode.auto);
        if (Platform.isMacOS) {
          expect(log.last.method, 'setFocusMode');
          expect(log.last.arguments, <String, dynamic>{
            'cameraId': 1,
            'mode': FocusMode.auto.index,
          });
          await plugin.setFocusMode(1, FocusMode.locked);
          expect(log.last.arguments, <String, dynamic>{
            'cameraId': 1,
            'mode': FocusMode.locked.index,
          });
        } else {
          expect(
            () => plugin.setFocusMode(1, FocusMode.locked),
            throwsA(isA<CameraException>()),
          );
        }
      },
    );

    test(
      'focus and exposure points delegate normalized macOS coordinates',
      () async {
        if (!Platform.isMacOS) return;

        await plugin.setFocusPoint(1, const Point<double>(0.25, 0.75));
        expect(log.last.method, 'setFocusPoint');
        expect(log.last.arguments, <String, dynamic>{
          'cameraId': 1,
          'point': <String, double>{'x': 0.25, 'y': 0.75},
        });

        await plugin.setExposurePoint(1, null);
        expect(log.last.method, 'setExposurePoint');
        expect(log.last.arguments, <String, dynamic>{
          'cameraId': 1,
          'point': null,
        });
      },
    );

    test(
      'pause and resume recording route through the macOS channel',
      () async {
        if (!Platform.isMacOS) return;

        await plugin.pauseVideoRecording(1);
        expect(log.last.method, 'pauseVideoRecording');
        expect(log.last.arguments, <String, dynamic>{'cameraId': 1});

        await plugin.resumeVideoRecording(1);
        expect(log.last.method, 'resumeVideoRecording');
        expect(log.last.arguments, <String, dynamic>{'cameraId': 1});
      },
    );

    for (final method in ['pauseVideoRecording', 'resumeVideoRecording']) {
      test('$method propagates a macOS native failure', () async {
        if (!Platform.isMacOS) return;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, method);
              throw PlatformException(
                code: 'recordingState',
                message: 'The recording cannot change state.',
              );
            });

        final operation = method == 'pauseVideoRecording'
            ? plugin.pauseVideoRecording(1)
            : plugin.resumeVideoRecording(1);
        await expectLater(
          operation,
          throwsA(
            isA<CameraException>().having(
              (error) => error.code,
              'code',
              'recordingState',
            ),
          ),
        );
      });
    }

    test('pause and resume recording remain unsupported off macOS', () async {
      if (Platform.isMacOS) return;
      await expectLater(
        plugin.pauseVideoRecording(1),
        throwsA(isA<CameraException>()),
      );
      await expectLater(
        plugin.resumeVideoRecording(1),
        throwsA(isA<CameraException>()),
      );
    });

    test('video stabilization exposes the supported macOS modes', () async {
      if (!Platform.isMacOS) return;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'getSupportedVideoStabilizationModes':
                expect(call.arguments, <String, dynamic>{'cameraId': 1});
                return <String>['off', 'unknown', 'level1'];
              case 'setVideoStabilizationMode':
                expect(call.arguments, <String, dynamic>{
                  'cameraId': 1,
                  'mode': 'level1',
                });
                return null;
              default:
                fail('Unexpected native call: ${call.method}');
            }
          });

      expect(await plugin.getSupportedVideoStabilizationModes(1), const [
        VideoStabilizationMode.off,
        VideoStabilizationMode.level1,
      ]);
      await plugin.setVideoStabilizationMode(1, VideoStabilizationMode.level1);

      await expectLater(
        plugin.setVideoStabilizationMode(1, VideoStabilizationMode.level2),
        throwsA(
          isA<CameraException>().having(
            (error) => error.code,
            'code',
            'unsupported_stabilization_mode',
          ),
        ),
      );
    });

    test(
      'video stabilization reports malformed native modes and failures',
      () async {
        if (!Platform.isMacOS) return;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'getSupportedVideoStabilizationModes');
              expect(call.arguments, <String, dynamic>{'cameraId': 1});
              return <String>['level1'];
            });

        await expectLater(
          plugin.getSupportedVideoStabilizationModes(1),
          throwsA(
            isA<CameraException>().having(
              (error) => error.code,
              'code',
              'invalid_stabilization_modes',
            ),
          ),
        );

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'setVideoStabilizationMode');
              expect(call.arguments, <String, dynamic>{
                'cameraId': 1,
                'mode': 'level1',
              });
              throw PlatformException(
                code: 'unsupported_configuration',
                message:
                    'Level 1 stabilization is unavailable at this quality.',
              );
            });

        await expectLater(
          plugin.setVideoStabilizationMode(1, VideoStabilizationMode.level1),
          throwsA(
            isA<CameraException>().having(
              (error) => error.code,
              'code',
              'unsupported_configuration',
            ),
          ),
        );
      },
    );

    test('video stabilization preserves nonmacOS fallback behavior', () async {
      if (Platform.isMacOS) return;

      expect(await plugin.getSupportedVideoStabilizationModes(1), const [
        VideoStabilizationMode.off,
      ]);
      expect(log, isEmpty);

      await plugin.setVideoStabilizationMode(1, VideoStabilizationMode.off);
      expect(log, isEmpty);
      await expectLater(
        plugin.setVideoStabilizationMode(1, VideoStabilizationMode.level1),
        throwsA(isA<CameraException>()),
      );
    });

    test('zoom returns 1.0 bounds', () async {
      expect(await plugin.getMinZoomLevel(1), 1.0);
      expect(await plugin.getMaxZoomLevel(1), 1.0);
    });

    test('exposure offset returns 0.0', () async {
      expect(await plugin.getMinExposureOffset(1), 0.0);
      expect(await plugin.getMaxExposureOffset(1), 0.0);
      expect(await plugin.getExposureOffsetStepSize(1), 0.0);
    });

    test('ImageStreamFfi.tryCreate returns null in test environment', () {
      // In the test environment, no native library is loaded, so FFI
      // symbol lookup should fail and tryCreate should return null.
      final ffi = ImageStreamFfi.tryCreate(1);
      expect(ffi, isNull);
    });

    test('onStreamedFrameAvailable uses MethodChannel fallback when FFI '
        'unavailable', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      // Start the image stream, should use MethodChannel fallback since
      // FFI symbols are not available in the test environment.
      final stream = plugin.onStreamedFrameAvailable(cameraId);
      final subscription = stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'startImageStream');

      await subscription.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'stopImageStream');
    });
  });
}
