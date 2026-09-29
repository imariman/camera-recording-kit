import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Native → Dart event contracts of the plugin.
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
}
