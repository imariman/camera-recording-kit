// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Native → Dart events and Dart → native argument contracts of the plugin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/camera_desktop');
  const description = CameraDescription(
    name: 'Test Camera (0x1234)',
    lensDirection: CameraLensDirection.external,
    sensorOrientation: 0,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late CameraDesktopPlugin plugin;
  late List<MethodCall> log;
  late Future<Object?> Function(MethodCall call) nativeHandler;

  setUp(() {
    plugin = CameraDesktopPlugin(channel: channel);
    log = <MethodCall>[];
    nativeHandler = (call) async => switch (call.method) {
      'create' => {'cameraId': 7, 'textureId': 70},
      _ => null,
    };
    messenger.setMockMethodCallHandler(channel, (call) {
      log.add(call);
      return nativeHandler(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Delivers a call from the native side into the plugin's handler.
  Future<void> sendFromNative(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  group('cameraError event', () {
    Future<CameraErrorEvent> errorFor(Map<String, Object?> arguments) async {
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      final event = plugin.onCameraError(cameraId).first;
      await sendFromNative('cameraError', {'cameraId': cameraId, ...arguments});
      return event.timeout(const Duration(seconds: 2));
    }

    test('macOS payload with description and message is delivered', () async {
      final event = await errorFor({
        'description': 'Camera session interrupted',
        'message': 'Camera session interrupted',
      });
      expect(event.cameraId, 7);
      expect(event.description, 'Camera session interrupted');
    });

    test('Linux and Windows payload with only description', () async {
      final event = await errorFor({'description': 'Pipeline error'});
      expect(event.description, 'Pipeline error');
    });

    test('legacy macOS payload with only message is still delivered', () async {
      final event = await errorFor({'message': 'Unknown runtime error'});
      expect(event.description, 'Unknown runtime error');
    });

    test('payload without text still emits an error event', () async {
      final event = await errorFor(const {});
      expect(event.description, isNotEmpty);
    });

    test('events are scoped to their camera', () async {
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      final received = <CameraErrorEvent>[];
      final subscription = plugin.onCameraError(cameraId).listen(received.add);
      await sendFromNative('cameraError', {
        'cameraId': cameraId + 1,
        'description': 'other camera',
      });
      await sendFromNative('cameraError', {
        'cameraId': cameraId,
        'description': 'this camera',
      });
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(received.map((e) => e.description), ['this camera']);
    });

    test('cameraClosing emits a closing event', () async {
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      final event = plugin.onCameraClosing(cameraId).first;
      await sendFromNative('cameraClosing', {'cameraId': cameraId});
      expect((await event).cameraId, cameraId);
    });
  });

  group('argument validation', () {
    test('create sends the camera name, preset, audio and fps', () async {
      await plugin.createCameraWithSettings(
        description,
        const MediaSettings(
          resolutionPreset: ResolutionPreset.veryHigh,
          fps: 60,
          videoBitrate: 8000000,
          audioBitrate: 96000,
          enableAudio: true,
        ),
      );
      expect(log.single.method, 'create');
      expect(log.single.arguments, <String, Object?>{
        'cameraName': 'Test Camera (0x1234)',
        'resolutionPreset': ResolutionPreset.veryHigh.index,
        'enableAudio': true,
        'fps': 60,
        'videoBitrate': 8000000,
        'audioBitrate': 96000,
      });
    });

    test(
      'create omits unset bitrates and defaults the preset to max',
      () async {
        await plugin.createCameraWithSettings(
          description,
          const MediaSettings(),
        );
        final arguments = log.single.arguments as Map<Object?, Object?>;
        expect(arguments['resolutionPreset'], ResolutionPreset.max.index);
        expect(arguments.containsKey('videoBitrate'), isFalse);
        expect(arguments.containsKey('audioBitrate'), isFalse);
      },
    );

    test('native create rejections surface as CameraException', () async {
      nativeHandler = (call) async => throw PlatformException(
        code: 'unsupportedRecordingProfile',
        message: 'Only explicit 30 or 60 FPS recording profiles are supported.',
      );
      await expectLater(
        plugin.createCameraWithSettings(
          description,
          const MediaSettings(fps: 24),
        ),
        throwsA(
          isA<CameraException>().having(
            (e) => e.code,
            'code',
            'unsupportedRecordingProfile',
          ),
        ),
      );
    });

    test('initialize failure emits an error event and throws', () async {
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      nativeHandler = (call) async => throw PlatformException(
        code: 'camera_disposed',
        message: 'The camera was disposed before initialization finished.',
      );
      final event = plugin.onCameraError(cameraId).first;
      await expectLater(
        plugin.initializeCamera(cameraId),
        throwsA(
          isA<CameraException>().having(
            (e) => e.code,
            'code',
            'camera_disposed',
          ),
        ),
      );
      expect(
        (await event).description,
        'The camera was disposed before initialization finished.',
      );
    });

    test('buildPreview requires a created camera', () {
      expect(() => plugin.buildPreview(99), throwsA(isA<CameraException>()));
    });

    test('stopVideoRecording rejects a reply without a path', () async {
      nativeHandler = (call) async => <String, Object?>{'framesDropped': 0};
      await expectLater(
        plugin.stopVideoRecording(1),
        throwsA(isA<CameraException>()),
      );
    });

    test('zoom other than 1.0 is rejected without a native call', () async {
      await plugin.setZoomLevel(1, 1.0);
      await expectLater(
        plugin.setZoomLevel(1, 2.0),
        throwsA(isA<CameraException>()),
      );
      expect(log, isEmpty);
    });

    test('streamCallback recording is rejected', () async {
      await expectLater(
        plugin.startVideoCapturing(
          VideoCaptureOptions(1, streamCallback: (_) {}),
        ),
        throwsA(isA<CameraException>()),
      );
      expect(log, isEmpty);
    });

    test('dispose swallows native failures', () async {
      nativeHandler = (call) async =>
          throw PlatformException(code: 'camera_not_found');
      await plugin.dispose(1);
      expect(log.single.method, 'dispose');
    });
  });
}
