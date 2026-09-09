// Copyright 2026 Teleprompter Studio. All rights reserved.

import 'package:flutter/services.dart';

const MethodChannel _recordingQualityChannel = MethodChannel(
  'dev.teleprompter/camera_desktop_recording_quality',
);

/// Returns the recordable quality profiles and focus/exposure support for
/// [cameraName] on macOS.
Future<Map<String, dynamic>> recordingQualityCapabilities(String cameraName) {
  return _invokeMap('recordingQualityCapabilities', <String, dynamic>{
    'cameraName': cameraName,
  });
}

/// Returns the active capture format actually applied to [cameraId] on macOS.
Future<Map<String, dynamic>> recordingQualityApplied(int cameraId) {
  return _invokeMap('recordingQualityApplied', <String, dynamic>{
    'cameraId': cameraId,
  });
}

/// Selects the video codec for the next desktop camera controller created on
/// macOS. Supported values are `h264` and `hevc` (H.265).
///
/// Call this before creating the controller. The native backend consumes this
/// one-shot selection when it receives the next `create` request, so a
/// controller that already exists is never silently reconfigured.
Future<void> setRecordingVideoCodec(String codec) async {
  final normalizedCodec = codec.toLowerCase();
  if (normalizedCodec != 'h264' && normalizedCodec != 'hevc') {
    throw ArgumentError.value(codec, 'codec', 'Must be h264 or hevc.');
  }
  await _recordingQualityChannel.invokeMethod<void>(
    'setRecordingVideoCodec',
    <String, dynamic>{'codec': normalizedCodec},
  );
}

/// Inspects finalized recording metadata without changing the file.
Future<Map<String, dynamic>> inspectRecordingMedia(String path) {
  return _invokeMap('inspectRecordingMedia', <String, dynamic>{'path': path});
}

/// Waits up to two seconds for autofocus and autoexposure to settle.
///
/// This never changes the active focus or exposure mode. It returns `false`
/// when the active camera cannot lock both focus and exposure.
Future<bool> waitForRecordingFocus(int cameraId) async {
  return await _recordingQualityChannel.invokeMethod<bool>(
        'waitForRecordingFocus',
        <String, dynamic>{'cameraId': cameraId},
      ) ??
      false;
}

Future<Map<String, dynamic>> _invokeMap(
  String method,
  Map<String, dynamic> arguments,
) async {
  final Map<dynamic, dynamic>? result = await _recordingQualityChannel
      .invokeMapMethod<dynamic, dynamic>(method, arguments);
  if (result == null) {
    throw PlatformException(
      code: 'recording_quality_empty_result',
      message: '$method returned no result.',
    );
  }
  return Map<String, dynamic>.from(result);
}
