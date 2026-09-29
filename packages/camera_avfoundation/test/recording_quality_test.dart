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
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return null;
          });

      await setRecordingVideoCodec('hevc');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'setRecordingVideoCodec');
      expect(calls.single.arguments, <String, dynamic>{'codec': 'hevc'});
    },
  );

  group('map results', () {
    for (final entry in <String, Future<Map<String, dynamic>> Function()>{
      'recordingQualityCapabilities': () =>
          recordingQualityCapabilities('back-camera'),
      'recordingQualityApplied': () => recordingQualityApplied(42),
      'inspectRecordingMedia': () => inspectRecordingMedia('/tmp/video.mp4'),
    }.entries) {
      test('${entry.key} throws when the platform returns null', () async {
        final methods = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              methods.add(call.method);
              return null;
            });

        await expectLater(
          entry.value(),
          throwsA(
            isA<PlatformException>()
                .having(
                  (PlatformException e) => e.code,
                  'code',
                  'recording_quality_empty_result',
                )
                .having(
                  (PlatformException e) => e.message,
                  'message',
                  contains(entry.key),
                ),
          ),
        );
        expect(methods, <String>[entry.key]);
      });
    }
  });

  test('inspectRecordingMedia passes the path and returns the map', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'inspectRecordingMedia');
          expect(call.arguments, <String, dynamic>{'path': '/tmp/video.mp4'});
          return <String, dynamic>{'width': 1920, 'codec': 'hevc'};
        });

    final metadata = await inspectRecordingMedia('/tmp/video.mp4');

    expect(metadata, <String, dynamic>{'width': 1920, 'codec': 'hevc'});
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

  test('waitForRecordingFocus returns true when focus converged', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => true);

    expect(await waitForRecordingFocus(7), isTrue);
  });

  test('waitForRecordingFocus treats a null result as false', () async {
    var called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          called = true;
          expect(call.method, 'waitForRecordingFocus');
          return null;
        });

    expect(await waitForRecordingFocus(7), isFalse);
    expect(called, isTrue);
  });
}
