// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.MediaFormat;
import android.media.MediaRecorder;
import android.util.Range;
import android.util.Size;
import androidx.annotation.NonNull;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.DynamicRange;
import androidx.camera.core.impl.EncoderProfilesProxy;
import androidx.camera.video.EncoderProfilesResolver;
import androidx.camera.video.Quality;
import androidx.camera.video.Recorder;
import androidx.camera.video.VideoCapabilities;
import androidx.camera.video.internal.VideoValidatedEncoderProfilesProxy;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.MockedConstruction;
import org.mockito.MockedStatic;
import org.mockito.Mockito;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

/** Tests the checks that decide which recording profiles are advertised as supported. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
public class RecordingQualityCapabilitiesTest {
  private static final Size FHD = new Size(1920, 1080);
  private static final Size UHD = new Size(3840, 2160);
  private static final long FRAME_DURATION_60_FPS = 16_666_666L;
  private static final long FRAME_DURATION_30_FPS = 33_333_333L;

  private RecordingQualityController controller;

  @Before
  public void setUp() {
    final Context context = mock(Context.class);
    when(context.getApplicationContext()).thenReturn(context);
    controller = new RecordingQualityController(context);
  }

  @After
  public void tearDown() {
    controller.tearDown();
  }

  @Test
  public void hasFixedFrameRateRange_requiresExactlyTheRequestedFrameRate() {
    assertTrue(
        RecordingQualityController.hasFixedFrameRateRange(
            new HashSet<>(Arrays.asList(new Range<>(15, 30), new Range<>(30, 30))), 30));
    // A variable range that only contains the frame rate is not enough: the readback asks for
    // exactly [fps, fps].
    assertFalse(
        RecordingQualityController.hasFixedFrameRateRange(
            new HashSet<>(Arrays.asList(new Range<>(15, 60), new Range<>(30, 60))), 60));
    assertFalse(
        RecordingQualityController.hasFixedFrameRateRange(
            Collections.singleton(new Range<>(30, 30)), 60));
  }

  @Test
  public void sensorSupportsFrameRate_checksRecordingSizeAndMinimumFrameDuration() {
    final StreamConfigurationMap map = streamConfigurationMap(FRAME_DURATION_60_FPS, FHD);

    assertTrue(RecordingQualityController.sensorSupportsFrameRate(map, FHD, 60));
    assertTrue(RecordingQualityController.sensorSupportsFrameRate(map, FHD, 30));
    // Not an output size for MediaRecorder.
    assertFalse(RecordingQualityController.sensorSupportsFrameRate(map, UHD, 30));
  }

  @Test
  public void sensorSupportsFrameRate_rejectsFrameRateAboveSensorLimit() {
    final StreamConfigurationMap map = streamConfigurationMap(FRAME_DURATION_30_FPS, FHD);

    assertTrue(RecordingQualityController.sensorSupportsFrameRate(map, FHD, 30));
    assertFalse(RecordingQualityController.sensorSupportsFrameRate(map, FHD, 60));
  }

  @Test
  public void sensorSupportsFrameRate_rejectsMissingOrUnreadableConfiguration() {
    assertFalse(RecordingQualityController.sensorSupportsFrameRate(null, FHD, 30));

    final StreamConfigurationMap noSizes = mock(StreamConfigurationMap.class);
    when(noSizes.getOutputSizes(MediaRecorder.class)).thenReturn(null);
    assertFalse(RecordingQualityController.sensorSupportsFrameRate(noSizes, FHD, 30));

    final StreamConfigurationMap throwing = mock(StreamConfigurationMap.class);
    when(throwing.getOutputSizes(MediaRecorder.class)).thenReturn(new Size[] {FHD});
    when(throwing.getOutputMinFrameDuration(MediaRecorder.class, FHD))
        .thenThrow(new IllegalArgumentException("unsupported size"));
    assertFalse(RecordingQualityController.sensorSupportsFrameRate(throwing, FHD, 30));
  }

  @Test
  public void encoderAccepts_usesHardwareEncoderWhenOneExists() {
    final List<RecordingQualityController.VideoEncoderInfo> encoders =
        Arrays.asList(
            encoder(true, MediaFormat.MIMETYPE_VIDEO_AVC, true),
            encoder(false, MediaFormat.MIMETYPE_VIDEO_AVC, true));

    assertTrue(
        RecordingQualityController.encoderAccepts(
            encoders, MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080, 60));
  }

  @Test
  public void encoderAccepts_ignoresSoftwareEncoderWhenHardwareEncoderRejects() {
    final List<RecordingQualityController.VideoEncoderInfo> encoders =
        Arrays.asList(
            encoder(true, MediaFormat.MIMETYPE_VIDEO_AVC, true),
            encoder(false, MediaFormat.MIMETYPE_VIDEO_AVC, false));

    assertFalse(
        RecordingQualityController.encoderAccepts(
            encoders, MediaFormat.MIMETYPE_VIDEO_AVC, 3840, 2160, 60));
  }

  @Test
  public void encoderAccepts_fallsBackToSoftwareEncoderWithoutHardwareEncoderForTheType() {
    final List<RecordingQualityController.VideoEncoderInfo> encoders =
        Arrays.asList(
            encoder(true, MediaFormat.MIMETYPE_VIDEO_AVC, true),
            // A hardware encoder of another type does not count.
            encoder(false, MediaFormat.MIMETYPE_VIDEO_HEVC, false));

    assertTrue(
        RecordingQualityController.encoderAccepts(
            encoders, MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720, 30));
  }

  @Test
  public void encoderAccepts_rejectsWithoutEncoderForTheType() {
    assertFalse(
        RecordingQualityController.encoderAccepts(
            Collections.singletonList(encoder(false, MediaFormat.MIMETYPE_VIDEO_HEVC, true)),
            MediaFormat.MIMETYPE_VIDEO_AVC,
            1920,
            1080,
            30));
    assertFalse(
        RecordingQualityController.encoderAccepts(
            Collections.emptyList(), MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080, 30));
  }

  @Test
  public void buildCapabilities_advertisesOnlyFixedFrameRateAvcProfiles() {
    final CameraInfo cameraInfo = mock(CameraInfo.class);
    // 60 fps is only reachable through variable ranges, so only 30 fps is advertised.
    when(cameraInfo.getSupportedFrameRateRanges())
        .thenReturn(
            new HashSet<>(
                Arrays.asList(new Range<>(15, 30), new Range<>(30, 30), new Range<>(15, 60))));
    when(cameraInfo.isFocusMeteringSupported(any())).thenReturn(true);

    final VideoCapabilities videoCapabilities = mock(VideoCapabilities.class);
    when(videoCapabilities.getSupportedQualities(DynamicRange.SDR))
        .thenReturn(Arrays.asList(Quality.UHD, Quality.FHD));
    when(videoCapabilities.getResolution(Quality.UHD, DynamicRange.SDR)).thenReturn(UHD);
    when(videoCapabilities.getResolution(Quality.FHD, DynamicRange.SDR)).thenReturn(FHD);
    final EncoderProfilesResolver profilesResolver = mock(EncoderProfilesResolver.class);
    // UHD only has an HEVC profile, which must not be advertised as h264.
    final VideoValidatedEncoderProfilesProxy uhdProfiles =
        encoderProfiles(videoProfile(UHD, MediaFormat.MIMETYPE_VIDEO_HEVC));
    final VideoValidatedEncoderProfilesProxy fhdProfiles =
        encoderProfiles(
            videoProfile(FHD, MediaFormat.MIMETYPE_VIDEO_HEVC),
            videoProfile(FHD, MediaFormat.MIMETYPE_VIDEO_AVC));
    when(profilesResolver.getProfiles(Quality.UHD, DynamicRange.SDR)).thenReturn(uhdProfiles);
    when(profilesResolver.getProfiles(Quality.FHD, DynamicRange.SDR)).thenReturn(fhdProfiles);
    final Recorder recorder = mock(Recorder.class);
    when(recorder.getMediaCapabilities(eq(cameraInfo), anyInt())).thenReturn(videoCapabilities);
    when(recorder.getEncoderProfilesResolver(eq(cameraInfo), anyInt()))
        .thenReturn(profilesResolver);

    final Camera2CameraInfo camera2CameraInfo = mock(Camera2CameraInfo.class);
    final StreamConfigurationMap map = streamConfigurationMap(FRAME_DURATION_60_FPS, FHD, UHD);
    when(camera2CameraInfo.getCameraCharacteristic(
            CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP))
        .thenReturn(map);
    when(camera2CameraInfo.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE))
        .thenReturn(true);
    final List<RecordingQualityController.VideoEncoderInfo> encoders =
        Arrays.asList(
            encoder(false, MediaFormat.MIMETYPE_VIDEO_AVC, true),
            encoder(false, MediaFormat.MIMETYPE_VIDEO_HEVC, true));

    final Map<String, Object> capabilities;
    try (MockedConstruction<Recorder.Builder> ignored =
            Mockito.mockConstruction(
                Recorder.Builder.class,
                (builder, context) -> when(builder.build()).thenReturn(recorder));
        MockedStatic<Camera2CameraInfo> mockedCamera2CameraInfo =
            Mockito.mockStatic(Camera2CameraInfo.class)) {
      mockedCamera2CameraInfo
          .when(() -> Camera2CameraInfo.from(cameraInfo))
          .thenReturn(camera2CameraInfo);
      capabilities = controller.buildCapabilities(cameraInfo, encoders);
    }

    final Map<String, Object> expectedProfile = new HashMap<>();
    expectedProfile.put("width", 1920);
    expectedProfile.put("height", 1080);
    expectedProfile.put("fps", 30);
    expectedProfile.put("codecs", Collections.singletonList("h264"));
    assertEquals(Collections.singletonList(expectedProfile), capabilities.get("profiles"));
    assertEquals(true, capabilities.get("supportsFocusLock"));
    assertEquals(true, capabilities.get("supportsExposureLock"));
  }

  private static StreamConfigurationMap streamConfigurationMap(
      long minimumFrameDuration, Size... sizes) {
    final StreamConfigurationMap map = mock(StreamConfigurationMap.class);
    when(map.getOutputSizes(MediaRecorder.class)).thenReturn(sizes);
    for (Size size : sizes) {
      when(map.getOutputMinFrameDuration(MediaRecorder.class, size))
          .thenReturn(minimumFrameDuration);
    }
    return map;
  }

  /** An encoder of {@code mimeType} that accepts every size and rate if {@code accepts}. */
  private static RecordingQualityController.VideoEncoderInfo encoder(
      boolean softwareOnly, String mimeType, boolean accepts) {
    return new RecordingQualityController.VideoEncoderInfo() {
      @Override
      public boolean supportsType(@NonNull String type) {
        return mimeType.equalsIgnoreCase(type);
      }

      @Override
      public boolean isSoftwareOnly() {
        return softwareOnly;
      }

      @Override
      public boolean acceptsSizeAndRate(@NonNull String type, int width, int height, int fps) {
        return supportsType(type) && accepts;
      }
    };
  }

  private static EncoderProfilesProxy.VideoProfileProxy videoProfile(Size size, String mimeType) {
    final EncoderProfilesProxy.VideoProfileProxy profile =
        mock(EncoderProfilesProxy.VideoProfileProxy.class);
    when(profile.getWidth()).thenReturn(size.getWidth());
    when(profile.getHeight()).thenReturn(size.getHeight());
    when(profile.getMediaType()).thenReturn(mimeType);
    return profile;
  }

  private static VideoValidatedEncoderProfilesProxy encoderProfiles(
      EncoderProfilesProxy.VideoProfileProxy... videoProfiles) {
    final VideoValidatedEncoderProfilesProxy profiles =
        mock(VideoValidatedEncoderProfilesProxy.class);
    final List<EncoderProfilesProxy.VideoProfileProxy> profileList = Arrays.asList(videoProfiles);
    when(profiles.getVideoProfiles()).thenReturn(profileList);
    return profiles;
  }
}
