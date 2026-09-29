// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import 'package:camera_android_camerax/recording_quality.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'plugins.flutter.io/camera_android_camerax/recording_quality',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'recordingQualityCapabilities forwards camera name and returns native map',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'recordingQualityCapabilities');
            expect(call.arguments, <String, Object?>{'cameraName': 'front-0'});
            return <String, Object?>{
              'profiles': <Map<String, Object?>>[
                <String, Object?>{
                  'width': 1920,
                  'height': 1080,
                  'fps': 30,
                  'codecs': <String>['h264'],
                },
              ],
              'supportsFocusLock': true,
              'supportsExposureLock': false,
            };
          });

      final result = await recordingQualityCapabilities('front-0');

      expect(result['supportsFocusLock'], isTrue);
      expect(result['supportsExposureLock'], isFalse);
      expect(result['profiles'], hasLength(1));
    },
  );

  test('setRecordingVideoCodec forwards supported codec', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'setRecordingVideoCodec');
          expect(call.arguments, <String, Object?>{'codec': 'h264'});
          return null;
        });

    await setRecordingVideoCodec('h264');
  });

  test(
    'setRecordingVideoCodec forwards hevc for native capability check',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'setRecordingVideoCodec');
            expect(call.arguments, <String, Object?>{'codec': 'hevc'});
            throw PlatformException(code: 'unsupportedVideoCodec');
          });

      await expectLater(
        setRecordingVideoCodec('hevc'),
        throwsA(
          isA<PlatformException>().having(
            (PlatformException error) => error.code,
            'code',
            'unsupportedVideoCodec',
          ),
        ),
      );
    },
  );

  test('setRecordingVideoCodec rejects unknown codec locally', () async {
    await expectLater(setRecordingVideoCodec('vp9'), throwsArgumentError);
  });

  test(
    'recordingQualityApplied returns the native readback with a pending codec',
    () async {
      // Shape of the map RecordingQualityController returns: fps and
      // stabilization always come from the CaptureResult readback, and only
      // the codec is unknown until the recording is finalized.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'recordingQualityApplied');
            expect(call.arguments, <String, Object?>{'cameraId': 42});
            return <String, Object?>{
              'width': 1280,
              'height': 720,
              'fps': 60,
              'stabilizationEnabled': true,
              'codec': null,
              'codecSource': 'unavailableUntilFinalized',
            };
          });

      final result = await recordingQualityApplied(42);

      expect(result, <String, Object?>{
        'width': 1280,
        'height': 720,
        'fps': 60,
        'stabilizationEnabled': true,
        'codec': null,
        'codecSource': 'unavailableUntilFinalized',
      });
      expect(result['fps'], isA<int>());
      expect(result['stabilizationEnabled'], isA<bool>());
    },
  );

  test('inspectRecordingMedia forwards finalized path', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'inspectRecordingMedia');
          expect(call.arguments, <String, Object?>{'path': '/tmp/final.mp4'});
          return <String, Object?>{
            'width': 3840,
            'height': 2160,
            'fpsSource': 'measured',
            'bitrateSource': 'estimated',
          };
        });

    final result = await inspectRecordingMedia('/tmp/final.mp4');

    expect(result['width'], 3840);
    expect(result['height'], 2160);
  });

  test(
    'waitForRecordingFocus returns unsupported result from native code',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'waitForRecordingFocus');
            expect(call.arguments, <String, Object?>{'cameraId': 7});
            return false;
          });

      expect(await waitForRecordingFocus(7), isFalse);
    },
  );

  test('native configuration errors remain PlatformExceptions', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          throw PlatformException(
            code: 'unsupportedRecordingProfile',
            message: 'CameraX could not bind 2160p60.',
          );
        });

    await expectLater(
      recordingQualityApplied(99),
      throwsA(
        isA<PlatformException>().having(
          (PlatformException error) => error.code,
          'code',
          'unsupportedRecordingProfile',
        ),
      ),
    );
  });
}
