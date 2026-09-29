// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

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
              'profiles': <Map<String, dynamic>>[
                <String, dynamic>{
                  'width': 1920,
                  'height': 1080,
                  'fps': 30,
                  'codecs': <String>['h264', 'hevc'],
                },
              ],
              'supportsFocusLock': true,
              'supportsExposureLock': true,
            };
          });

      final capabilities = await recordingQualityCapabilities('back-camera');

      expect(capabilities['supportsFocusLock'], isTrue);
      expect(capabilities['profiles'], hasLength(1));
      expect(
        (capabilities['profiles'] as List<Object?>).single,
        containsPair('codecs', <String>['h264', 'hevc']),
      );
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
            'codec': 'hevc',
          };
        });

    final applied = await recordingQualityApplied(42);

    expect(applied['fps'], 60);
    expect(applied['stabilizationEnabled'], isFalse);
    expect(applied['codec'], 'hevc');
  });

  test(
    'setRecordingVideoCodec passes an HEVC request before camera creation',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'setRecordingVideoCodec');
            expect(call.arguments, <String, dynamic>{'codec': 'hevc'});
            return null;
          });

      await setRecordingVideoCodec('hevc');
    },
  );

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
