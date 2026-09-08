import 'package:flutter/foundation.dart';

/// Represents the user's preferred recording-quality intent.
///
/// These values do not guarantee a resolution, frame rate, or codec. The camera
/// layer selects an appropriate platform setting for this intent.
enum RecordingQualityIntent { automatic, high, balanced, compact }

/// Explicit recording targets; Automatic is resolved independently per lens.
enum RecordingResolution { automatic, hd, fullHd, ultraHd }

extension RecordingResolutionDimensions on RecordingResolution {
  int get height => switch (this) {
    RecordingResolution.automatic => 2160,
    RecordingResolution.hd => 720,
    RecordingResolution.fullHd => 1080,
    RecordingResolution.ultraHd => 2160,
  };
}

@immutable
class RecordingProfile {
  const RecordingProfile({
    this.recordAudio = true,
    this.quality = RecordingQualityIntent.automatic,
    this.resolution = RecordingResolution.automatic,
    this.fps = 30,
  });

  /// Whether the camera controller records audio with the video stream.
  final bool recordAudio;
  final RecordingQualityIntent quality;
  final RecordingResolution resolution;
  final int fps;

  RecordingProfile copyWith({
    bool? recordAudio,
    RecordingQualityIntent? quality,
    RecordingResolution? resolution,
    int? fps,
  }) => RecordingProfile(
    recordAudio: recordAudio ?? this.recordAudio,
    quality: quality ?? this.quality,
    resolution: resolution ?? this.resolution,
    fps: fps ?? this.fps,
  );

  Map<String, dynamic> toJson() {
    return {
      'version': 2,
      'recordAudio': recordAudio,
      'quality': quality.name,
      'resolution': resolution.name,
      'fps': fps,
    };
  }

  factory RecordingProfile.fromJson(Map<String, dynamic> json) {
    final qualityName = json['quality'];

    return RecordingProfile(
      resolution: RecordingResolution.values.firstWhere(
        (value) => value.name == json['resolution'],
        orElse: () => RecordingResolution.automatic,
      ),
      fps: json['fps'] == 60 ? 60 : 30,
      recordAudio: json['recordAudio'] is bool
          ? json['recordAudio'] as bool
          : true,
      quality: RecordingQualityIntent.values.firstWhere(
        (quality) => quality.name == qualityName,
        orElse: () => RecordingQualityIntent.automatic,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RecordingProfile &&
        other.recordAudio == recordAudio &&
        other.quality == quality &&
        other.resolution == resolution &&
        other.fps == fps;
  }

  @override
  int get hashCode => Object.hash(recordAudio, quality, resolution, fps);
}
