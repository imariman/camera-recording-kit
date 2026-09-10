// Copyright 2026 Teleprompter Studio. All rights reserved.

import 'package:flutter/services.dart';

const MethodChannel _recordingQualityChannel = MethodChannel(
  'dev.teleprompter/recording_quality',
);

/// Returns the recordable quality profiles and focus/exposure lock support for
/// [cameraName].
Future<Map<String, dynamic>> recordingQualityCapabilities(String cameraName) {
  return _invokeMap('recordingQualityCapabilities', <String, dynamic>{
    'cameraName': cameraName,
  });
}

/// Returns the active capture format actually applied to [cameraId].
Future<Map<String, dynamic>> recordingQualityApplied(int cameraId) {
  return _invokeMap('recordingQualityApplied', <String, dynamic>{
    'cameraId': cameraId,
  });
}

/// Selects the video codec for the next camera controller created by this
/// process.
///
/// This must be called before creating a camera controller. Supported values
/// are `h264` and `hevc`; the latter is also known as H.265. Use
/// [recordingQualityCapabilities] to determine whether a particular capture
/// profile can use HEVC on the current device.
Future<void> setRecordingVideoCodec(String codec) async {
  await _recordingQualityChannel.invokeMethod<void>(
    'setRecordingVideoCodec',
    <String, dynamic>{'codec': codec},
  );
}

/// Inspects finalized media at [path] without changing the recording file.
Future<Map<String, dynamic>> inspectRecordingMedia(String path) {
  return _invokeMap('inspectRecordingMedia', <String, dynamic>{'path': path});
}

/// Waits for autofocus and autoexposure to settle without changing either mode.
///
/// Returns `false` when the active lens cannot lock focus or exposure, or when
/// either adjustment has not settled within two seconds.
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
