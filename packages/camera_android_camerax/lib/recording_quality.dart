// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/services.dart';

const MethodChannel _recordingQualityChannel = MethodChannel(
  'plugins.flutter.io/camera_android_camerax/recording_quality',
);

/// Returns verified SDR recording profiles and lock capabilities for the
/// camera identified by the CameraX camera name.
///
/// Each profile contains integer `width`, `height`, and `fps` values. Only
/// 30 or 60 FPS combinations validated against CameraX, a containing camera
/// frame-rate range, per-size sensor duration, and encoder constraints are
/// returned.
Future<Map<String, dynamic>> recordingQualityCapabilities(String cameraName) {
  return _invokeMap('recordingQualityCapabilities', <String, Object?>{
    'cameraName': cameraName,
  });
}

/// Returns the profile currently applied to the bound recording use case.
///
/// The map contains integer `width` and `height`, nullable numeric `fps`, and
/// nullable boolean `stabilizationEnabled` values. A profile that CameraX did
/// not finish binding is reported as a [PlatformException] with code
/// `unsupportedRecordingProfile`.
Future<Map<String, dynamic>> recordingQualityApplied(int cameraId) {
  return _invokeMap('recordingQualityApplied', <String, Object?>{
    'cameraId': cameraId,
  });
}

/// Reads the finalized MP4 container metadata at [path] without decoding video
/// frames.
Future<Map<String, dynamic>> inspectRecordingMedia(String path) {
  return _invokeMap('inspectRecordingMedia', <String, Object?>{'path': path});
}

/// Observes the active metering target for at most two seconds and returns true
/// only after native autofocus and auto-exposure both converge.
///
/// This does not submit or lock a metering request, so a tap-to-focus point is
/// preserved. Returns false when focus metering is unsupported or convergence
/// misses the deadline. Native camera errors are surfaced as
/// [PlatformException]s.
Future<bool> waitForRecordingFocus(int cameraId) async {
  final bool? result = await _recordingQualityChannel.invokeMethod<bool>(
    'waitForRecordingFocus',
    <String, Object?>{'cameraId': cameraId},
  );
  if (result == null) {
    throw PlatformException(
      code: 'invalidRecordingQualityResponse',
      message: 'The Android camera backend returned no focus result.',
    );
  }
  return result;
}

Future<Map<String, dynamic>> _invokeMap(
  String method,
  Map<String, Object?> arguments,
) async {
  final Map<Object?, Object?>? result = await _recordingQualityChannel
      .invokeMethod<Map<Object?, Object?>>(method, arguments);
  if (result == null) {
    throw PlatformException(
      code: 'invalidRecordingQualityResponse',
      message: 'The Android camera backend returned no result for $method.',
    );
  }
  return result.cast<String, dynamic>();
}
