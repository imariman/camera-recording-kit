// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.robolectric.Shadows.shadowOf;

import android.content.Context;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.os.Looper;
import android.util.Range;
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
import java.time.Duration;
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
  private static final Duration POLL_INTERVAL = Duration.ofMillis(50);
  private static final Duration PAST_APPLIED_PROFILE_DEADLINE = Duration.ofMillis(2_100);

  private RecordingQualityController controller;
  private MockedStatic<Camera2CameraControl> mockedCamera2CameraControl;
  private CaptureRequestOptions requestedOptions;
  private Preview boundPreview;
  private VideoCapture<Recorder> boundVideoCapture;

  @Before
  public void setUp() {
    final Context context = mock(Context.class);
    when(context.getApplicationContext()).thenReturn(context);
    controller = new RecordingQualityController(context);

    requestedOptions = mock(CaptureRequestOptions.class);
    final Camera2CameraControl camera2CameraControl = mock(Camera2CameraControl.class);
    when(camera2CameraControl.getCaptureRequestOptions()).thenReturn(requestedOptions);
    mockedCamera2CameraControl = Mockito.mockStatic(Camera2CameraControl.class);
    mockedCamera2CameraControl
        .when(() -> Camera2CameraControl.from(any(CameraControl.class)))
        .thenReturn(camera2CameraControl);
  }

  @After
  public void tearDown() {
    controller.tearDown();
    mockedCamera2CameraControl.close();
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
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        controller.createConvergenceTracker();
    final CameraControl reboundCameraControl = mock(CameraControl.class);

    bindThenRebindPreviewOnly(
        videoCapture,
        tracker,
        mockCamera(mock(CameraControl.class), mock(CameraInfo.class)),
        mockCamera(reboundCameraControl, mock(CameraInfo.class)));
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("recordingQualityApplied"), result);

    // The stabilization request is read from the rebound camera's control.
    mockedCamera2CameraControl.verify(() -> Camera2CameraControl.from(reboundCameraControl));
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

  @Test
  public void recordingQualityApplied_waitsForCaptureResultBeforeAnswering() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);
    verify(result, never()).success(any());

    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    shadowOf(Looper.getMainLooper()).idleFor(POLL_INTERVAL);

    verify(result).success(appliedProfile(60, false));
  }

  @Test
  public void recordingQualityApplied_reportsCaptureResultFrameRateInsteadOfEncoderRequest() {
    // The encoder was asked for 60 fps, but the camera runs the session at 30 fps.
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);
    verify(result, never()).success(any());
    shadowOf(Looper.getMainLooper()).idleFor(PAST_APPLIED_PROFILE_DEADLINE);

    verify(result).success(appliedProfile(30, false));
    verify(result, never()).success(appliedProfile(60, false));
  }

  @Test
  public void recordingQualityApplied_rejectsVariableCaptureFrameRateRange() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    deliver(
        tracker,
        captureResult(new Range<>(15, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);
    shadowOf(Looper.getMainLooper()).idleFor(PAST_APPLIED_PROFILE_DEADLINE);

    verify(result).error(eq("unsupportedRecordingProfile"), anyString(), isNull());
    verify(result, never()).success(any());
  }

  @Test
  public void recordingQualityApplied_rejectsWhenNoCaptureResultArrives() {
    bindRecordingCamera(60);
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);
    shadowOf(Looper.getMainLooper()).idleFor(PAST_APPLIED_PROFILE_DEADLINE);

    verify(result).error(eq("unsupportedRecordingProfile"), anyString(), isNull());
    verify(result, never()).success(any());
  }

  @Test
  public void recordingQualityApplied_waitsForRequestedStabilizationToReachCaptureResult() {
    requestStabilizationMode(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON);
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);
    verify(result, never()).success(any());

    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON));
    shadowOf(Looper.getMainLooper()).idleFor(POLL_INTERVAL);

    verify(result).success(appliedProfile(60, true));
  }

  @Test
  public void recordingQualityApplied_reportsStabilizationOffWhenCaptureResultNeverConfirmsIt() {
    // Stabilization was requested, but the camera keeps reporting it off.
    requestStabilizationMode(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON);
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);
    shadowOf(Looper.getMainLooper()).idleFor(PAST_APPLIED_PROFILE_DEADLINE);

    verify(result).success(appliedProfile(60, false));
    verify(result, never()).success(appliedProfile(60, true));
  }

  @Test
  public void recordingQualityApplied_reportsStabilizationOffWhenCaptureResultOmitsMode() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(30);
    deliver(tracker, captureResult(new Range<>(30, 30), null));
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(appliedCall(), result);

    verify(result).success(appliedProfile(30, false));
  }

  @Test
  public void registerBoundCamera_discardsCaptureResultsFromPreviousBinding() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON));

    controller.registerBoundCamera(
        mock(CameraSelector.class), Arrays.asList(boundPreview, boundVideoCapture), mockCamera());

    assertNull(tracker.getObservedAeTargetFpsRange());
    assertNull(tracker.getObservedVideoStabilizationMode());
  }

  @Test
  public void registerBoundCamera_keepsCaptureResultsAcrossPreviewOnlyRebind() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(60);
    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON));

    // resumePreview rebinds only the Preview; the recording session is unchanged.
    controller.registerBoundCamera(
        mock(CameraSelector.class), Collections.singletonList(boundPreview), mockCamera());

    assertEquals(new Range<>(60, 60), tracker.getObservedAeTargetFpsRange());
    assertEquals(
        Integer.valueOf(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON),
        tracker.getObservedVideoStabilizationMode());
    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), result);
    verify(result).success(appliedProfile(60, true));
  }

  @SuppressWarnings("unchecked")
  private RecordingQualityController.RecordingConvergenceTracker bindRecordingCamera(
      int encoderFrameRate) {
    final Recorder recorder = mock(Recorder.class);
    when(recorder.getVideoEncodingFrameRate()).thenReturn(encoderFrameRate);
    final ResolutionInfo resolutionInfo = mock(ResolutionInfo.class);
    when(resolutionInfo.getResolution()).thenReturn(new Size(1920, 1080));
    boundVideoCapture = mock(VideoCapture.class);
    when(boundVideoCapture.getOutput()).thenReturn(recorder);
    when(boundVideoCapture.getResolutionInfo()).thenReturn(resolutionInfo);
    boundPreview = mock(Preview.class);

    // Mirrors the production order: Preview, then VideoCapture.withOutput, then bindToLifecycle.
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        controller.createConvergenceTracker();
    controller.registerPreview(boundPreview, CAMERA_ID);
    controller.registerVideoCapture(boundVideoCapture, tracker);
    controller.registerBoundCamera(
        mock(CameraSelector.class), Arrays.asList(boundPreview, boundVideoCapture), mockCamera());
    return tracker;
  }

  private static Camera mockCamera() {
    final Camera camera = mock(Camera.class);
    when(camera.getCameraControl()).thenReturn(mock(CameraControl.class));
    when(camera.getCameraInfo()).thenReturn(mock(CameraInfo.class));
    return camera;
  }

  private void requestStabilizationMode(int mode) {
    when(requestedOptions.getCaptureRequestOption(
            CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE))
        .thenReturn(mode);
  }

  private static TotalCaptureResult captureResult(
      Range<Integer> aeTargetFpsRange, Integer videoStabilizationMode) {
    final TotalCaptureResult captureResult = mock(TotalCaptureResult.class);
    when(captureResult.get(CaptureResult.CONTROL_AE_TARGET_FPS_RANGE))
        .thenReturn(aeTargetFpsRange);
    when(captureResult.get(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE))
        .thenReturn(videoStabilizationMode);
    return captureResult;
  }

  private static void deliver(
      RecordingQualityController.RecordingConvergenceTracker tracker,
      TotalCaptureResult captureResult) {
    tracker.onCaptureCompleted(
        mock(CameraCaptureSession.class), mock(CaptureRequest.class), captureResult);
  }

  private static Map<String, Object> appliedProfile(int fps, boolean stabilizationEnabled) {
    final Map<String, Object> applied = new HashMap<>();
    applied.put("width", 1920);
    applied.put("height", 1080);
    applied.put("fps", fps);
    applied.put("codec", null);
    applied.put("codecSource", "unavailableUntilFinalized");
    applied.put("stabilizationEnabled", stabilizationEnabled);
    return applied;
  }

  private static MethodCall appliedCall() {
    return new MethodCall(
        "recordingQualityApplied", Collections.singletonMap("cameraId", CAMERA_ID));
  }

  private MethodCall codecCall(String codec) {
    final Map<String, Object> arguments = new HashMap<>();
    arguments.put("codec", codec);
    return new MethodCall("setRecordingVideoCodec", arguments);
  }
}
