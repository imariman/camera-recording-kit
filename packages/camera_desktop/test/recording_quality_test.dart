// Copyright 2026 Teleprompter Studio. All rights reserved.

import 'package:camera_desktop/recording_quality.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'dev.teleprompter/camera_desktop_recording_quality',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('capabilities forwards the selected desktop camera name', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'recordingQualityCapabilities');
          expect(call.arguments, <String, dynamic>{
            'cameraName': 'FaceTime HD Camera (camera-unique-id)',
          });
          return <String, dynamic>{
            'cameraUniqueId': 'camera-unique-id',
            'cameraType': 'internal',
            'profiles': <Map<String, int>>[
              <String, int>{'width': 1920, 'height': 1080, 'fps': 30},
            ],
            'supportsFocusLock': true,
            'supportsExposureLock': true,
            'supportsVideoStabilization': false,
            'supportsRecordingPause': false,
          };
        });

    final capabilities = await recordingQualityCapabilities(
      'FaceTime HD Camera (camera-unique-id)',
    );

    expect(capabilities['cameraType'], 'internal');
    expect(capabilities['supportsVideoStabilization'], isFalse);
    expect(capabilities['profiles'], hasLength(1));
  });

  test('applied quality forwards the active camera ID', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'recordingQualityApplied');
          expect(call.arguments, <String, dynamic>{'cameraId': 42});
          return <String, dynamic>{
            'width': 1280,
            'height': 720,
            'fps': 60.0,
            'configuredWidth': 1280,
            'configuredHeight': 720,
            'stabilizationEnabled': false,
          };
        });

    final applied = await recordingQualityApplied(42);

    expect(applied['fps'], 60.0);
    expect(applied['stabilizationEnabled'], isFalse);
  });

  test('media inspection forwards the finalized path', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'inspectRecordingMedia');
          expect(call.arguments, <String, dynamic>{
            'path': '/tmp/recording.mp4',
          });
          return <String, dynamic>{
            'width': 3840,
            'height': 2160,
            'codec': 'avc1',
            'fileSizeBytes': 1234,
          };
        });

    final metadata = await inspectRecordingMedia('/tmp/recording.mp4');

    expect(metadata['codec'], 'avc1');
    expect(metadata['fileSizeBytes'], 1234);
  });

  test('focus wait returns false for an unsupported desktop lens', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'waitForRecordingFocus');
          expect(call.arguments, <String, dynamic>{'cameraId': 7});
          return false;
        });

    expect(await waitForRecordingFocus(7), isFalse);
  });

  test('a missing map result is surfaced as a platform error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);

    await expectLater(
      recordingQualityApplied(1),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'recording_quality_empty_result',
        ),
      ),
    );
  });
}
