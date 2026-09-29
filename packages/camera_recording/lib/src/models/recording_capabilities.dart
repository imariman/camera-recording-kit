import 'package:flutter/foundation.dart';

import 'package:camera_recording/src/models/recording_profile.dart';

/// Values reported in [AppliedRecordingProfile.fallbackReason] and
/// `RecordedMediaMetadata.fallbackReason`. A null reason means the requested
/// profile was applied exactly.
abstract final class RecordingFallbackReason {
  /// The best candidate for the request was rejected by the camera
  /// configuration, and a later candidate was applied instead.
  static const configurationRejected = 'configurationRejected';

  /// The lens does not offer the requested resolution, frame rate, or codec,
  /// so the closest supported format was applied instead. This includes a
  /// lens whose smallest format is larger than an explicit target.
  static const unsupportedProfile = 'unsupportedProfile';

  /// The finalized file's dimensions or frame rate differ from the configured
  /// format although configuration itself was exact.
  static const encodedMismatch = 'encodedMismatch';
}

/// One capture mode: dimensions, frame rate, and the codecs available for it.
///
/// Equality and [hashCode] identify the capture mode only (orientation-agnostic
/// dimensions and frame rate). [codecs] is deliberately excluded so a format
/// advertised with several codecs still matches the single-codec format read
/// back from the active camera; compare [codecs] explicitly when it matters.
@immutable
class RecordingVideoFormat {
  const RecordingVideoFormat({
    required this.width,
    required this.height,
    required this.fps,
    this.codecs = const {RecordingVideoCodec.h264},
  });
  final int width;
  final int height;
  final int fps;
  final Set<RecordingVideoCodec> codecs;

  int get shortSide => width < height ? width : height;
  int get longSide => width > height ? width : height;

  static RecordingVideoFormat? tryParse(Map<Object?, Object?> map) {
    final width = map['width'];
    final height = map['height'];
    final fps = map['fps'];
    if (width is! int ||
        height is! int ||
        fps is! num ||
        !fps.isFinite ||
        width <= 0 ||
        height <= 0 ||
        width > 8192 ||
        height > 8192) {
      return null;
    }
    final rounded = fps.round();
    if (rounded != 30 && rounded != 60) return null;
    final rawCodecs = map['codecs'];
    final rawCodec = map['codec'];
    final codecs = <RecordingVideoCodec>{};
    if (rawCodecs is List) {
      for (final entry in rawCodecs) {
        for (final codec in RecordingVideoCodec.values) {
          if (entry == codec.name) codecs.add(codec);
        }
      }
    }
    for (final codec in RecordingVideoCodec.values) {
      if (rawCodec == codec.name) codecs.add(codec);
    }
    if (codecs.isEmpty && rawCodecs == null && rawCodec == null) {
      codecs.add(RecordingVideoCodec.h264);
    }
    if (codecs.isEmpty) return null;
    return RecordingVideoFormat(
      width: width,
      height: height,
      fps: rounded,
      codecs: Set.unmodifiable(codecs),
    );
  }

  bool supportsCodec(RecordingVideoCodec codec) => codecs.contains(codec);

  RecordingVideoFormat mergeCodecs(RecordingVideoFormat other) =>
      RecordingVideoFormat(
        width: width,
        height: height,
        fps: fps,
        codecs: Set.unmodifiable({...codecs, ...other.codecs}),
      );

  @override
  bool operator ==(Object other) =>
      other is RecordingVideoFormat &&
      longSide == other.longSide &&
      shortSide == other.shortSide &&
      fps == other.fps;
  @override
  int get hashCode => Object.hash(longSide, shortSide, fps);

  @override
  String toString() =>
      'RecordingVideoFormat(${width}x$height@$fps, '
      '${codecs.map((codec) => codec.name).join('/')})';
}

@immutable
class RecordingCapabilities {
  const RecordingCapabilities({
    this.profiles = const [],
    this.supportsFocusLock = false,
    this.supportsExposureLock = false,
  });
  final List<RecordingVideoFormat> profiles;
  final bool supportsFocusLock;
  final bool supportsExposureLock;

  factory RecordingCapabilities.fromJson(Map<Object?, Object?> json) {
    final formats = <RecordingVideoFormat>[];
    final raw = json['profiles'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final value = RecordingVideoFormat.tryParse(entry);
        if (value == null || value.shortSide > 2160) continue;
        final duplicateIndex = formats.indexOf(value);
        if (duplicateIndex < 0) {
          formats.add(value);
        } else {
          formats[duplicateIndex] = formats[duplicateIndex].mergeCodecs(value);
        }
      }
    }
    return RecordingCapabilities(
      profiles: List.unmodifiable(formats),
      supportsFocusLock: json['supportsFocusLock'] == true,
      supportsExposureLock: json['supportsExposureLock'] == true,
    );
  }

  List<RecordingResolution> get resolutions => [
    RecordingResolution.automatic,
    for (final resolution in RecordingResolution.values.skip(1))
      if (profiles.any((format) => format.shortSide == resolution.height))
        resolution,
  ];

  List<int> frameRates(RecordingResolution resolution) => [
    for (final fps in [30, 60])
      if (profiles.any(
        (format) =>
            format.fps == fps &&
            (resolution == RecordingResolution.automatic ||
                format.shortSide == resolution.height),
      ))
        fps,
  ];

  Set<RecordingVideoCodec> codecs({
    required RecordingResolution resolution,
    required int fps,
  }) => {
    for (final format in profiles)
      if (format.fps == fps &&
          (resolution == RecordingResolution.automatic ||
              format.shortSide == resolution.height))
        ...format.codecs,
  };

  /// Candidate formats for [request], best first.
  ///
  /// An explicit resolution is resolution-first, then FPS, then the requested
  /// codec. For [RecordingResolution.automatic] there is no resolution to
  /// honor, so formats at the requested frame rate come first (1080p60 beats
  /// 2160p30 for `fps: 60`), matching what [frameRates] offers for automatic.
  /// Ties with the same short side and frame rate prefer the wider format.
  ///
  /// An explicit target is never upgraded while the lens has a format at or
  /// below it. When it has none (for example a remembered 480p profile on a
  /// lens whose smallest format is 720p), the formats at the closest larger
  /// resolution are returned instead, so that switching to such a lens does
  /// not fail. `CameraService` reports that result as
  /// [RecordingFallbackReason.unsupportedProfile].
  ///
  /// HEVC requests retain an H.264 attempt for the same exact format before
  /// falling back to a lower resolution or frame rate.
  List<RecordingVideoFormat> candidates(RecordingProfile request) {
    bool frameRateAllowed(RecordingVideoFormat format) =>
        format.fps == request.fps || format.fps == 30;
    final target = request.resolution.height;
    var pool = [
      for (final format in profiles)
        if (frameRateAllowed(format) && format.shortSide <= target) format,
    ];
    if (pool.isEmpty && request.resolution != RecordingResolution.automatic) {
      final larger = [
        for (final format in profiles)
          if (frameRateAllowed(format) && format.shortSide > target) format,
      ];
      if (larger.isNotEmpty) {
        final closest = larger
            .map((format) => format.shortSide)
            .reduce((a, b) => a < b ? a : b);
        pool = [
          for (final format in larger)
            if (format.shortSide == closest) format,
        ];
      }
    }
    final formats = <RecordingVideoFormat>[];
    for (final format in pool) {
      if (format.supportsCodec(request.videoCodec)) {
        formats.add(
          RecordingVideoFormat(
            width: format.width,
            height: format.height,
            fps: format.fps,
            codecs: {request.videoCodec},
          ),
        );
      }
      if (request.videoCodec == RecordingVideoCodec.hevc &&
          format.supportsCodec(RecordingVideoCodec.h264)) {
        formats.add(
          RecordingVideoFormat(
            width: format.width,
            height: format.height,
            fps: format.fps,
          ),
        );
      }
    }
    final automatic = request.resolution == RecordingResolution.automatic;
    formats.sort((a, b) {
      if (automatic) {
        final aMatches = a.fps == request.fps ? 1 : 0;
        final bMatches = b.fps == request.fps ? 1 : 0;
        final requestedRate = bMatches.compareTo(aMatches);
        if (requestedRate != 0) return requestedRate;
      }
      final resolution = b.shortSide.compareTo(a.shortSide);
      if (resolution != 0) return resolution;
      final frameRate = b.fps.compareTo(a.fps);
      if (frameRate != 0) return frameRate;
      final width = b.longSide.compareTo(a.longSide);
      if (width != 0) return width;
      final aPreferred = a.supportsCodec(request.videoCodec) ? 1 : 0;
      final bPreferred = b.supportsCodec(request.videoCodec) ? 1 : 0;
      return bPreferred.compareTo(aPreferred);
    });
    return formats;
  }
}

/// The profile verified by native readback on the active camera.
@immutable
class AppliedRecordingProfile {
  const AppliedRecordingProfile({
    required this.requested,
    required this.format,
    required this.cameraName,
    required this.lensDirection,
    this.fallbackReason,
    this.stabilizationEnabled = false,
  });
  final RecordingProfile requested;
  final RecordingVideoFormat format;
  final String cameraName;
  final String lensDirection;

  /// Null when [format] matches the request exactly; otherwise one of the
  /// [RecordingFallbackReason] values. An automatic resolution is satisfied by
  /// the best format of the lens, whatever its size, so a sub-HD result for
  /// automatic is not a fallback by itself.
  final String? fallbackReason;

  /// True only when native readback confirmed active stabilization.
  final bool stabilizationEnabled;

  AppliedRecordingProfile copyWith({
    RecordingProfile? requested,
    bool? stabilizationEnabled,
  }) => AppliedRecordingProfile(
    requested: requested ?? this.requested,
    format: format,
    cameraName: cameraName,
    lensDirection: lensDirection,
    fallbackReason: fallbackReason,
    stabilizationEnabled: stabilizationEnabled ?? this.stabilizationEnabled,
  );
}
