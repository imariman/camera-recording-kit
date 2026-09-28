// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.content.Context;
import android.util.Size;
import androidx.camera.camera2.interop.Camera2CameraControl;
import androidx.camera.camera2.interop.CaptureRequestOptions;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraControl;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.Preview;
import androidx.camera.core.ResolutionInfo;
import androidx.camera.core.UseCase;
import androidx.camera.video.Recorder;
import androidx.camera.video.VideoCapture;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.mockito.MockedStatic;
import org.mockito.Mockito;
import org.robolectric.annotation.Config;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
public class RecordingQualityControllerTest {
  private static final long CAMERA_ID = 7L;

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
  public void supportedRecordingCodecs_returnsOnlyH264() {
    assertEquals(Collections.singletonList("h264"), controller.supportedRecordingCodecs());
  }

  @Test
  public void setRecordingVideoCodec_acceptsH264() {
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(codecCall("h264"), result);

    verify(result).success(null);
  }

  @Test
  public void setRecordingVideoCodec_rejectsHevcAsUnsupported() {
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(codecCall("hevc"), result);

    verify(result)
        .error(
            "unsupportedVideoCodec",
            "CameraX Recorder does not expose a public API for selecting HEVC video.",
            null);
  }

  @Test
  public void setRecordingVideoCodec_rejectsUnknownCodecAsInvalidArgument() {
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(codecCall("vp9"), result);

    verify(result)
        .error(eq("invalidArguments"), eq("codec must be h264 or hevc."), any());
  }

  @Test
  public void recordingQualityApplied_keepsVideoCaptureAfterPreviewOnlyRebind() {
    final VideoCapture<Recorder> videoCapture = mockVideoCapture();
    final ResolutionInfo resolutionInfo = mock(ResolutionInfo.class);
    when(resolutionInfo.getResolution()).thenReturn(new Size(1920, 1080));
    when(videoCapture.getResolutionInfo()).thenReturn(resolutionInfo);
    final Recorder recorder = mock(Recorder.class);
    when(recorder.getVideoEncodingFrameRate()).thenReturn(30);
    when(videoCapture.getOutput()).thenReturn(recorder);
    final CameraControl reboundCameraControl = mock(CameraControl.class);

    bindThenRebindPreviewOnly(
        videoCapture,
        mock(RecordingQualityController.RecordingConvergenceTracker.class),
        mockCamera(mock(CameraControl.class), mock(CameraInfo.class)),
        mockCamera(reboundCameraControl, mock(CameraInfo.class)));

    final Camera2CameraControl camera2CameraControl = mock(Camera2CameraControl.class);
    when(camera2CameraControl.getCaptureRequestOptions())
        .thenReturn(mock(CaptureRequestOptions.class));
    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    try (MockedStatic<Camera2CameraControl> mockedCamera2CameraControl =
        Mockito.mockStatic(Camera2CameraControl.class)) {
      mockedCamera2CameraControl
          .when(() -> Camera2CameraControl.from(any()))
          .thenReturn(camera2CameraControl);

      controller.onMethodCall(cameraIdCall("recordingQualityApplied"), result);

      mockedCamera2CameraControl.verify(() -> Camera2CameraControl.from(reboundCameraControl));
    }

    verify(result, never()).error(any(), any(), any());
    final ArgumentCaptor<Object> appliedCaptor = ArgumentCaptor.forClass(Object.class);
    verify(result).success(appliedCaptor.capture());
    final Map<?, ?> applied = (Map<?, ?>) appliedCaptor.getValue();
    assertEquals(1920, applied.get("width"));
    assertEquals(1080, applied.get("height"));
    assertEquals(30, applied.get("fps"));
  }

  @Test
  public void waitForRecordingFocus_keepsConvergenceTrackerAfterPreviewOnlyRebind() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        mock(RecordingQualityController.RecordingConvergenceTracker.class);
    final CameraControl reboundCameraControl = mock(CameraControl.class);
    final CameraInfo reboundCameraInfo = mock(CameraInfo.class);
    when(reboundCameraInfo.isFocusMeteringSupported(any())).thenReturn(true);

    bindThenRebindPreviewOnly(
        mockVideoCapture(),
        tracker,
        mockCamera(mock(CameraControl.class), mock(CameraInfo.class)),
        mockCamera(reboundCameraControl, reboundCameraInfo));

    // Focus metering on the rebound camera must still reset the tracker.
    controller.onFocusMeteringStarted(reboundCameraControl);
    verify(tracker).reset();

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("waitForRecordingFocus"), result);

    verify(tracker).waitForConvergence(eq(result), any(), any(), eq(2L));
    verify(result, never()).success(false);
  }

  /**
   * Binds Preview and VideoCapture together, then rebinds only the Preview to a new camera the way
   * {@code resumePreview} does after {@code pausePreview}.
   */
  private void bindThenRebindPreviewOnly(
      VideoCapture<?> videoCapture,
      RecordingQualityController.RecordingConvergenceTracker tracker,
      Camera initialCamera,
      Camera reboundCamera) {
    final CameraSelector selector = mock(CameraSelector.class);
    final Preview preview = mock(Preview.class);
    controller.registerPreview(preview, CAMERA_ID);
    controller.registerVideoCapture(videoCapture, tracker);
    controller.registerBoundCamera(
        selector, Arrays.<UseCase>asList(preview, videoCapture), initialCamera);
    controller.registerBoundCamera(selector, Collections.singletonList(preview), reboundCamera);
  }

  @SuppressWarnings("unchecked")
  private static VideoCapture<Recorder> mockVideoCapture() {
    return mock(VideoCapture.class);
  }

  private static Camera mockCamera(CameraControl cameraControl, CameraInfo cameraInfo) {
    final Camera camera = mock(Camera.class);
    when(camera.getCameraControl()).thenReturn(cameraControl);
    when(camera.getCameraInfo()).thenReturn(cameraInfo);
    return camera;
  }

  private MethodCall cameraIdCall(String method) {
    final Map<String, Object> arguments = new HashMap<>();
    arguments.put("cameraId", CAMERA_ID);
    return new MethodCall(method, arguments);
  }

  private MethodCall codecCall(String codec) {
    final Map<String, Object> arguments = new HashMap<>();
    arguments.put("codec", codec);
    return new MethodCall("setRecordingVideoCodec", arguments);
  }
}
