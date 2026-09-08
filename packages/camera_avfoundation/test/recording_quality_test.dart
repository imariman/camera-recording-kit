// Copyright 2026 Teleprompter Studio. All rights reserved.

import 'package:camera_avfoundation/recording_quality.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.teleprompter/recording_quality');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'recordingQualityCapabilities passes the selected camera name',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'recordingQualityCapabilities');
            expect(call.arguments, <String, dynamic>{
              'cameraName': 'back-camera',
            });
            return <String, dynamic>{
              'profiles': <Map<String, int>>[
                <String, int>{'width': 1920, 'height': 1080, 'fps': 30},
              ],
              'supportsFocusLock': true,
              'supportsExposureLock': true,
            };
          });

      final capabilities = await recordingQualityCapabilities('back-camera');

      expect(capabilities['supportsFocusLock'], isTrue);
      expect(capabilities['profiles'], hasLength(1));
    },
  );

  test('recordingQualityApplied passes the active texture ID', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'recordingQualityApplied');
          expect(call.arguments, <String, dynamic>{'cameraId': 42});
          return <String, dynamic>{
            'width': 1280,
            'height': 720,
            'fps': 60,
            'stabilizationEnabled': false,
          };
        });

    final applied = await recordingQualityApplied(42);

    expect(applied['fps'], 60);
    expect(applied['stabilizationEnabled'], isFalse);
  });

  test('waitForRecordingFocus returns false for an unsupported lens', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'waitForRecordingFocus');
          expect(call.arguments, <String, dynamic>{'cameraId': 7});
          return false;
        });

    expect(await waitForRecordingFocus(7), isFalse);
  });
}
