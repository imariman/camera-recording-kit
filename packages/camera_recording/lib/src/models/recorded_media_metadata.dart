import 'package:flutter/foundation.dart';

/// Best-effort technical metadata for a completed recording.
///
/// Every field is nullable because platform inspectors can return partial or
/// malformed data. Invalid individual values are discarded without making the
/// containing recording take unreadable.
@immutable
class RecordedMediaMetadata {
  const RecordedMediaMetadata({
    this.width,
    this.height,
    this.durationMilliseconds,
    this.rotationDegrees,
    this.fps,
    this.fpsSource,
    this.bitrate,
    this.bitrateSource,
    this.codec,
    this.mimeType,
    this.fileSizeBytes,
    this.cameraName,
    this.lensDirection,
    this.configuredWidth,
    this.configuredHeight,
    this.configuredFps,
    this.fallbackReason,
  });

  static const int currentSchemaVersion = 1;

  final int? width;
  final int? height;
  final int? durationMilliseconds;
  final int? rotationDegrees;
  final double? fps;
  final String? fpsSource;
  final int? bitrate;
  final String? bitrateSource;

  /// Platform values parsed by [tryParse] are normalized to `h264` or `hevc`
  /// for known AVC/HEVC identifiers.
  final String? codec;
  final String? mimeType;
  final int? fileSizeBytes;

  final String? cameraName;
  final String? lensDirection;
  final int? configuredWidth;
  final int? configuredHeight;
  final int? configuredFps;
  final String? fallbackReason;

  RecordedMediaMetadata copyWith({
    int? width,
    int? height,
    int? durationMilliseconds,
    int? rotationDegrees,
    double? fps,
    String? fpsSource,
    int? bitrate,
    String? bitrateSource,
    String? codec,
    String? mimeType,
    int? fileSizeBytes,
    String? cameraName,
    String? lensDirection,
    int? configuredWidth,
    int? configuredHeight,
    int? configuredFps,
    String? fallbackReason,
  }) {
    return RecordedMediaMetadata(
      width: width ?? this.width,
      height: height ?? this.height,
      durationMilliseconds: durationMilliseconds ?? this.durationMilliseconds,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      fps: fps ?? this.fps,
      fpsSource: fpsSource ?? this.fpsSource,
      bitrate: bitrate ?? this.bitrate,
      bitrateSource: bitrateSource ?? this.bitrateSource,
      codec: codec ?? this.codec,
      mimeType: mimeType ?? this.mimeType,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      cameraName: cameraName ?? this.cameraName,
      lensDirection: lensDirection ?? this.lensDirection,
      configuredWidth: configuredWidth ?? this.configuredWidth,
      configuredHeight: configuredHeight ?? this.configuredHeight,
      configuredFps: configuredFps ?? this.configuredFps,
      fallbackReason: fallbackReason ?? this.fallbackReason,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': currentSchemaVersion,
      'width': width,
      'height': height,
      'durationMilliseconds': durationMilliseconds,
      'rotationDegrees': rotationDegrees,
      'fps': fps,
      'fpsSource': fpsSource,
      'bitrate': bitrate,
      'bitrateSource': bitrateSource,
      'codec': codec,
      'mimeType': mimeType,
      'fileSizeBytes': fileSizeBytes,
      'cameraName': cameraName,
      'lensDirection': lensDirection,
      'configuredWidth': configuredWidth,
      'configuredHeight': configuredHeight,
      'configuredFps': configuredFps,
      'fallbackReason': fallbackReason,
    };
  }

  static RecordedMediaMetadata? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final version = _integer(raw['schemaVersion']);
    if (raw.containsKey('schemaVersion') && version != currentSchemaVersion) {
      return null;
    }

    return RecordedMediaMetadata(
      width: _positiveInteger(raw['width']),
      height: _positiveInteger(raw['height']),
      durationMilliseconds: _nonNegativeInteger(raw['durationMilliseconds']),
      rotationDegrees: _integer(raw['rotationDegrees']),
      fps: _positiveFiniteDouble(raw['fps']),
      fpsSource: _allowedString(raw['fpsSource'], const {
        'measured',
        'nominal',
      }),
      bitrate: _positiveInteger(raw['bitrate']),
      bitrateSource: _allowedString(raw['bitrateSource'], const {
        'estimated',
        'measured',
      }),
      codec: _normalizedCodec(raw['codec']),
      mimeType: _nonEmptyString(raw['mimeType']),
      fileSizeBytes: _positiveInteger(raw['fileSizeBytes']),
      cameraName: _nonEmptyString(raw['cameraName']),
      lensDirection: _nonEmptyString(raw['lensDirection']),
      configuredWidth: _positiveInteger(raw['configuredWidth']),
      configuredHeight: _positiveInteger(raw['configuredHeight']),
      configuredFps: _positiveInteger(raw['configuredFps']),
      fallbackReason: _nonEmptyString(raw['fallbackReason']),
    );
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    return null;
  }

  static int? _positiveInteger(Object? value) {
    final parsed = _integer(value);
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static int? _nonNegativeInteger(Object? value) {
    final parsed = _integer(value);
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  static double? _positiveFiniteDouble(Object? value) {
    if (value is! num) return null;
    final parsed = value.toDouble();
    return parsed.isFinite && parsed > 0 ? parsed : null;
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _allowedString(Object? value, Set<String> allowed) {
    final parsed = _nonEmptyString(value);
    return parsed != null && allowed.contains(parsed) ? parsed : null;
  }

  static String? _normalizedCodec(Object? value) {
    final parsed = _nonEmptyString(value);
    if (parsed == null) return null;
    final normalized = parsed.toLowerCase();
    if (normalized == 'h264' ||
        normalized == 'avc' ||
        normalized == 'video/avc' ||
        normalized.startsWith('avc1') ||
        normalized.startsWith('avc3')) {
      return 'h264';
    }
    if (normalized == 'h265' ||
        normalized == 'hevc' ||
        normalized == 'video/hevc' ||
        normalized == 'video/h265' ||
        normalized.startsWith('hvc1') ||
        normalized.startsWith('hev1')) {
      return 'hevc';
    }
    return parsed;
  }

  @override
  bool operator ==(Object other) {
    return other is RecordedMediaMetadata &&
        other.width == width &&
        other.height == height &&
        other.durationMilliseconds == durationMilliseconds &&
        other.rotationDegrees == rotationDegrees &&
        other.fps == fps &&
        other.fpsSource == fpsSource &&
        other.bitrate == bitrate &&
        other.bitrateSource == bitrateSource &&
        other.codec == codec &&
        other.mimeType == mimeType &&
        other.fileSizeBytes == fileSizeBytes &&
        other.cameraName == cameraName &&
        other.lensDirection == lensDirection &&
        other.configuredWidth == configuredWidth &&
        other.configuredHeight == configuredHeight &&
        other.configuredFps == configuredFps &&
        other.fallbackReason == fallbackReason;
  }

  @override
  int get hashCode => Object.hashAll([
    width,
    height,
    durationMilliseconds,
    rotationDegrees,
    fps,
    fpsSource,
    bitrate,
    bitrateSource,
    codec,
    mimeType,
    fileSizeBytes,
    cameraName,
    lensDirection,
    configuredWidth,
    configuredHeight,
    configuredFps,
    fallbackReason,
  ]);
}
