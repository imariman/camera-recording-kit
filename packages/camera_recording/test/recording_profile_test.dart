import 'package:flutter_test/flutter_test.dart';
import 'package:camera_recording/camera_recording.dart';

void main() {
  group('RecordingProfile', () {
    test('verifies recording profile behavior 1', () {
      const profile = RecordingProfile();

      expect(profile.recordAudio, isTrue);
      expect(profile.quality, RecordingQualityIntent.automatic);
      expect(profile.resolution, RecordingResolution.automatic);
      expect(profile.fps, 30);
    });

    test('verifies recording profile behavior 2', () {
      const profile = RecordingProfile(
        recordAudio: true,
        quality: RecordingQualityIntent.balanced,
        resolution: RecordingResolution.fullHd,
        fps: 60,
      );

      final updated = profile.copyWith(recordAudio: false);

      expect(updated.recordAudio, isFalse);
      expect(updated.quality, RecordingQualityIntent.balanced);
      expect(updated.resolution, RecordingResolution.fullHd);
      expect(updated.fps, 60);
    });

    test('verifies recording profile behavior 3', () {
      const profile = RecordingProfile(
        recordAudio: false,
        quality: RecordingQualityIntent.compact,
        resolution: RecordingResolution.fullHd,
        fps: 60,
      );

      final restored = RecordingProfile.fromJson(profile.toJson());

      expect(restored, profile);
    });

    test('verifies recording profile behavior 4', () {
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
    });

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
  });
}
