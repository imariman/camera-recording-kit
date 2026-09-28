import 'package:flutter_test/flutter_test.dart';
import 'package:camera_recording/camera_recording.dart';

void main() {
  group('RecordingProfile', () {
    test(
      'defaults to audio on, automatic quality and resolution, 30 fps, automatic bitrate, H.264, and unlocked orientation',
      () {
        const profile = RecordingProfile();

        expect(profile.recordAudio, isTrue);
        expect(profile.quality, RecordingQualityIntent.automatic);
        expect(profile.resolution, RecordingResolution.automatic);
        expect(profile.fps, 30);
        expect(profile.bitratePreset, RecordingBitratePreset.automatic);
        expect(profile.videoCodec, RecordingVideoCodec.h264);
        expect(profile.lockOrientation, isFalse);
      },
    );

    test(
      'copyWith changes only recordAudio and preserves every other field',
      () {
        const profile = RecordingProfile(
          recordAudio: true,
          quality: RecordingQualityIntent.balanced,
          resolution: RecordingResolution.fullHd,
          fps: 60,
          bitratePreset: RecordingBitratePreset.high,
          videoCodec: RecordingVideoCodec.hevc,
          lockOrientation: true,
        );

        final updated = profile.copyWith(recordAudio: false);

        expect(updated.recordAudio, isFalse);
        expect(updated.quality, RecordingQualityIntent.balanced);
        expect(updated.resolution, RecordingResolution.fullHd);
        expect(updated.fps, 60);
        expect(updated.bitratePreset, RecordingBitratePreset.high);
        expect(updated.videoCodec, RecordingVideoCodec.hevc);
        expect(updated.lockOrientation, isTrue);
      },
    );

    test('toJson and fromJson round-trip a fully customized profile', () {
      const profile = RecordingProfile(
        recordAudio: false,
        quality: RecordingQualityIntent.compact,
        resolution: RecordingResolution.fullHd,
        fps: 60,
        bitratePreset: RecordingBitratePreset.dataSaver,
        videoCodec: RecordingVideoCodec.hevc,
        lockOrientation: true,
      );

      final restored = RecordingProfile.fromJson(profile.toJson());

      expect(restored, profile);
    });

    test(
      'fromJson falls back to defaults for mistyped, unknown, unsupported, and missing values',
      () {
        final restored = RecordingProfile.fromJson({
          'recordAudio': 'false',
          'quality': 'futureQuality',
          'resolution': 'futureResolution',
          'fps': 120,
        });

        expect(restored.recordAudio, isTrue);
        expect(restored.quality, RecordingQualityIntent.automatic);
        expect(restored.resolution, RecordingResolution.automatic);
        expect(restored.fps, 30);
        expect(restored.bitratePreset, RecordingBitratePreset.automatic);
        expect(restored.videoCodec, RecordingVideoCodec.h264);
        expect(restored.lockOrientation, isFalse);
      },
    );

    test('legacy JSON çözünürlük ve kare hızında otomatik 30a düşer', () {
      final restored = RecordingProfile.fromJson(const {
        'recordAudio': false,
        'quality': 'high',
      });

      expect(restored.recordAudio, isFalse);
      expect(restored.quality, RecordingQualityIntent.high);
      expect(restored.resolution, RecordingResolution.automatic);
      expect(restored.fps, 30);
    });

    test('480p and new recording preferences round-trip safely', () {
      const profile = RecordingProfile(
        recordAudio: false,
        resolution: RecordingResolution.standardDefinition,
        fps: 30,
        bitratePreset: RecordingBitratePreset.balanced,
        videoCodec: RecordingVideoCodec.hevc,
        lockOrientation: true,
      );

      expect(RecordingProfile.fromJson(profile.toJson()), profile);
      expect(RecordingResolution.standardDefinition.height, 480);
    });

    test('storage estimate reflects bitrate, codec, and audio choices', () {
      const format = RecordingVideoFormat(width: 1920, height: 1080, fps: 30);
      const h264 = RecordingProfile(
        resolution: RecordingResolution.fullHd,
        bitratePreset: RecordingBitratePreset.balanced,
      );
      const hevcSilent = RecordingProfile(
        recordAudio: false,
        resolution: RecordingResolution.fullHd,
        bitratePreset: RecordingBitratePreset.balanced,
        videoCodec: RecordingVideoCodec.hevc,
      );

      expect(RecordingStorageEstimate.videoBitrate(h264, format), 10000000);
      expect(
        RecordingStorageEstimate.megabytesPerMinute(h264, format),
        closeTo(75.96, 0.01),
      );
      expect(
        RecordingStorageEstimate.megabytesPerMinute(hevcSilent, format),
        lessThan(RecordingStorageEstimate.megabytesPerMinute(h264, format)),
      );
    });
  });
}
