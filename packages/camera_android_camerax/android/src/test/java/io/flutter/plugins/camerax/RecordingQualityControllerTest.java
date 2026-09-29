// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
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
import android.os.Handler;
import android.os.Looper;
import android.util.Range;
import android.util.Size;
import androidx.camera.camera2.interop.Camera2CameraControl;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.CaptureRequestOptions;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraControl;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.Preview;
import androidx.camera.core.ResolutionInfo;
import androidx.camera.core.UseCase;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.video.Recorder;
import androidx.camera.video.VideoCapture;
import com.google.common.util.concurrent.Futures;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.time.Duration;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
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
    // ContextCompat.getMainExecutor(context) delegates to Context#getMainExecutor.
    when(context.getMainExecutor())
        .thenReturn(command -> new Handler(Looper.getMainLooper()).post(command));
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

  @Test
  public void recordingQualityApplied_keepsVideoCaptureAfterCameraSwitchWithPausedPreview() {
    final VideoCapture<Recorder> videoCapture = mockVideoCapture();
    final ResolutionInfo resolutionInfo = mock(ResolutionInfo.class);
    when(resolutionInfo.getResolution()).thenReturn(new Size(1920, 1080));
    when(videoCapture.getResolutionInfo()).thenReturn(resolutionInfo);
    final Recorder recorder = mock(Recorder.class);
    when(recorder.getVideoEncodingFrameRate()).thenReturn(30);
    when(videoCapture.getOutput()).thenReturn(recorder);
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        controller.createConvergenceTracker();
    final CameraControl switchedCameraControl = mock(CameraControl.class);

    switchCameraWithPausedPreview(
        videoCapture,
        tracker,
        mockCamera(mock(CameraControl.class), mock(CameraInfo.class)),
        mockCamera(switchedCameraControl, mock(CameraInfo.class)),
        mockCamera(switchedCameraControl, mock(CameraInfo.class)));
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("recordingQualityApplied"), result);

    mockedCamera2CameraControl.verify(() -> Camera2CameraControl.from(switchedCameraControl));
    verify(result, never()).error(any(), any(), any());
    verify(result).success(appliedProfile(30, false));
  }

  @Test
  public void waitForRecordingFocus_keepsConvergenceTrackerAfterCameraSwitchWithPausedPreview() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        mock(RecordingQualityController.RecordingConvergenceTracker.class);
    final CameraControl switchedCameraControl = mock(CameraControl.class);
    final CameraInfo switchedCameraInfo = mock(CameraInfo.class);
    when(switchedCameraInfo.isFocusMeteringSupported(any())).thenReturn(true);

    switchCameraWithPausedPreview(
        mockVideoCapture(),
        tracker,
        mockCamera(mock(CameraControl.class), mock(CameraInfo.class)),
        mockCamera(switchedCameraControl, switchedCameraInfo),
        mockCamera(switchedCameraControl, switchedCameraInfo));

    controller.onFocusMeteringStarted(switchedCameraControl);
    verify(tracker).reset();

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("waitForRecordingFocus"), result);

    verify(tracker).waitForConvergence(eq(result), any(), any(), eq(2L));
    verify(result, never()).success(false);
  }

  @Test
  public void registerBoundCamera_ignoresVideoCaptureNeverBoundWithAPreview() {
    final VideoCapture<Recorder> videoCapture = mockVideoCapture();
    controller.registerVideoCapture(videoCapture, controller.createConvergenceTracker());

    controller.registerBoundCamera(
        mock(CameraSelector.class), Collections.singletonList(videoCapture), mockCamera());

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("recordingQualityApplied"), result);
    verify(result).error(eq("cameraNotBound"), anyString(), isNull());
  }

  @Test
  public void registerBoundCamera_ignoresBindWithUnregisteredPreviewEvenIfVideoCaptureIsKnown() {
    final VideoCapture<Recorder> videoCapture = mockVideoCapture();
    final Preview registeredPreview = mock(Preview.class);
    controller.registerPreview(registeredPreview, CAMERA_ID);
    controller.registerVideoCapture(videoCapture, controller.createConvergenceTracker());
    controller.registerBoundCamera(
        mock(CameraSelector.class),
        Arrays.<UseCase>asList(registeredPreview, videoCapture),
        mockCamera());
    controller.clearBoundCameras();

    // The VideoCapture is paired with CAMERA_ID, but this bind carries a Preview that was never
    // registered, so it must not be stored under the old id.
    controller.registerBoundCamera(
        mock(CameraSelector.class),
        Arrays.<UseCase>asList(mock(Preview.class), videoCapture),
        mockCamera());

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("recordingQualityApplied"), result);
    verify(result).error(eq("cameraNotBound"), anyString(), isNull());
  }

  /**
   * Mirrors {@code setDescriptionWhileRecording} with a paused preview: the initial bind carries
   * Preview and VideoCapture, {@code unbindAll} clears every registration, the camera switch binds
   * only the VideoCapture, and {@code resumePreview} later binds only the Preview.
   */
  private void switchCameraWithPausedPreview(
      VideoCapture<?> videoCapture,
      RecordingQualityController.RecordingConvergenceTracker tracker,
      Camera initialCamera,
      Camera switchedCamera,
      Camera resumedCamera) {
    final Preview preview = mock(Preview.class);
    controller.registerPreview(preview, CAMERA_ID);
    controller.registerVideoCapture(videoCapture, tracker);
    controller.registerBoundCamera(
        mock(CameraSelector.class), Arrays.<UseCase>asList(preview, videoCapture), initialCamera);

    controller.clearBoundCameras();
    controller.registerBoundCamera(
        mock(CameraSelector.class), Collections.singletonList(videoCapture), switchedCamera);
    controller.registerBoundCamera(
        mock(CameraSelector.class), Collections.singletonList(preview), resumedCamera);
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

  @Test
  public void recordingQualityApplied_keepsWorkingForTheNextRecordingWhileVideoCaptureStaysBound() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(30);
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    final MethodChannel.Result firstRecording = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), firstRecording);
    verify(firstRecording).success(appliedProfile(30, false));

    // stopVideoRecording no longer unbinds anything, so the session keeps delivering results to
    // the same tracker and the next recording's readback answers without a rebind.
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    final MethodChannel.Result secondRecording = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), secondRecording);
    verify(secondRecording).success(appliedProfile(30, false));
  }

  @Test
  public void onUseCasesUnbound_videoCaptureFailsReadbackFastAndStopsFocusTracking() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        mock(RecordingQualityController.RecordingConvergenceTracker.class);
    final CameraControl cameraControl = mock(CameraControl.class);
    final CameraInfo cameraInfo = mock(CameraInfo.class);
    when(cameraInfo.isFocusMeteringSupported(any())).thenReturn(true);
    final VideoCapture<Recorder> videoCapture = mockVideoCapture();
    final Preview preview = mock(Preview.class);
    controller.registerPreview(preview, CAMERA_ID);
    controller.registerVideoCapture(videoCapture, tracker);
    controller.registerBoundCamera(
        mock(CameraSelector.class),
        Arrays.<UseCase>asList(preview, videoCapture),
        mockCamera(cameraControl, cameraInfo));

    controller.onUseCasesUnbound(Collections.singletonList(videoCapture));

    controller.onFocusMeteringStarted(cameraControl);
    verify(tracker, never()).reset();
    final MethodChannel.Result focusResult = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("waitForRecordingFocus"), focusResult);
    verify(focusResult).success(false);
    verify(tracker, never()).waitForConvergence(any(), any(), any(), anyLong());

    final MethodChannel.Result appliedResult = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), appliedResult);
    // Answered at once instead of polling for results that no longer arrive.
    verify(appliedResult).error(eq("unsupportedRecordingProfile"), anyString(), isNull());
  }

  @Test
  public void onUseCasesUnbound_previewOnlyKeepsTheRecordingSession() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(30);

    // pausePreview unbinds only the Preview; the VideoCapture and its session stay bound.
    controller.onUseCasesUnbound(Collections.singletonList(boundPreview));
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), result);
    verify(result).success(appliedProfile(30, false));
  }

  @Test
  public void registerBoundCamera_restoresRegistrationWhenUnboundVideoCaptureIsBoundAgain() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(30);
    controller.onUseCasesUnbound(Collections.singletonList(boundVideoCapture));

    // Upstream-style start: VideoCapture bound again on its own.
    controller.registerBoundCamera(
        mock(CameraSelector.class), Collections.singletonList(boundVideoCapture), mockCamera());
    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));

    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), result);
    verify(result).success(appliedProfile(30, false));
  }

  @Test
  public void recordingQualityCapabilities_buildsOffTheMainThreadAndAnswersOnIt()
      throws Exception {
    final CameraInfo cameraInfo = mock(CameraInfo.class);
    final RecordingQualityController spyController = Mockito.spy(controller);
    final Map<String, Object> capabilities = Collections.singletonMap("profiles", "built");
    final Thread[] buildThread = {null};
    Mockito.doAnswer(
            invocation -> {
              buildThread[0] = Thread.currentThread();
              return capabilities;
            })
        .when(spyController)
        .buildCapabilities(cameraInfo);
    final CapturingResult result = new CapturingResult();

    try (AutoCloseable ignoredLookup = mockCameraLookup(cameraInfo)) {
      spyController.onMethodCall(capabilitiesCall(), result);
      awaitResult(result);
    }

    assertEquals("success", result.outcome);
    assertEquals(capabilities, result.value);
    assertNotEquals(Looper.getMainLooper().getThread(), buildThread[0]);
    assertEquals(Looper.getMainLooper().getThread(), result.thread);
  }

  @Test
  public void recordingQualityCapabilities_reportsBuildFailureOnTheMainThread() throws Exception {
    final CameraInfo cameraInfo = mock(CameraInfo.class);
    final RecordingQualityController spyController = Mockito.spy(controller);
    Mockito.doThrow(new IllegalStateException("capabilities unavailable"))
        .when(spyController)
        .buildCapabilities(cameraInfo);
    final CapturingResult result = new CapturingResult();

    try (AutoCloseable ignoredLookup = mockCameraLookup(cameraInfo)) {
      spyController.onMethodCall(capabilitiesCall(), result);
      awaitResult(result);
    }

    assertEquals("error", result.outcome);
    assertEquals("recordingQualityFailure", result.errorCode);
    assertEquals(Looper.getMainLooper().getThread(), result.thread);
  }

  @Test
  public void inspectRecordingMedia_inspectsOffTheMainThreadAndAnswersOnIt() throws Exception {
    final Map<String, Object> metadata = Collections.singletonMap("width", 1920);
    final Thread[] inspectThread = {null};
    final RecordingMediaInspector inspector = mock(RecordingMediaInspector.class);
    when(inspector.inspect(any()))
        .thenAnswer(
            invocation -> {
              inspectThread[0] = Thread.currentThread();
              return metadata;
            });
    final CapturingResult result = inspect(inspector);

    assertEquals("success", result.outcome);
    assertEquals(metadata, result.value);
    assertNotEquals(Looper.getMainLooper().getThread(), inspectThread[0]);
    assertEquals(Looper.getMainLooper().getThread(), result.thread);
  }

  @Test
  public void inspectRecordingMedia_reportsInspectionErrorCode() throws Exception {
    final RecordingMediaInspector inspector = mock(RecordingMediaInspector.class);
    when(inspector.inspect(any()))
        .thenThrow(
            new RecordingMediaInspector.MediaInspectionException(
                "recordingMediaNotFound", "missing", null));

    final CapturingResult result = inspect(inspector);

    assertEquals("error", result.outcome);
    assertEquals("recordingMediaNotFound", result.errorCode);
    assertEquals(Looper.getMainLooper().getThread(), result.thread);
  }

  @Test
  public void inspectRecordingMedia_reportsUnexpectedFailureAsInvalidMedia() throws Exception {
    final RecordingMediaInspector inspector = mock(RecordingMediaInspector.class);
    when(inspector.inspect(any())).thenThrow(new IllegalStateException("extractor crashed"));

    final CapturingResult result = inspect(inspector);

    assertEquals("error", result.outcome);
    assertEquals("recordingMediaInvalid", result.errorCode);
    assertEquals(Looper.getMainLooper().getThread(), result.thread);
  }

  @Test
  public void inspectRecordingMedia_reportsAnErrorAfterTearDown() {
    controller.tearDown();
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(
        new MethodCall("inspectRecordingMedia", Collections.singletonMap("path", "/a.mp4")),
        result);

    verify(result).error(eq("recordingQualityFailure"), anyString(), any());
  }

  @Test
  public void waitForRecordingFocus_answersTrueOnceAfAndAeConvergeInCaptureResults() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(30, focusMeteringSupportedCamera());
    final MethodChannel.Result result = mock(MethodChannel.Result.class);

    controller.onMethodCall(cameraIdCall("waitForRecordingFocus"), result);
    // Only AF converged: keep waiting.
    deliver(
        tracker,
        convergenceResult(
            CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED,
            CaptureResult.CONTROL_AE_STATE_SEARCHING));
    shadowOf(Looper.getMainLooper()).idle();
    verify(result, never()).success(any());

    deliver(
        tracker,
        convergenceResult(
            CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED,
            CaptureResult.CONTROL_AE_STATE_CONVERGED));
    shadowOf(Looper.getMainLooper()).idle();

    verify(result).success(true);
  }

  @Test
  public void waitForRecordingFocus_waitsForNewConvergenceAfterFocusMeteringStarts() {
    final Camera camera = focusMeteringSupportedCamera();
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        bindRecordingCamera(30, camera);
    deliver(
        tracker,
        convergenceResult(
            CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED,
            CaptureResult.CONTROL_AE_STATE_CONVERGED));

    // A new metering request (for example tap to focus) invalidates the earlier convergence.
    controller.onFocusMeteringStarted(camera.getCameraControl());
    final MethodChannel.Result result = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("waitForRecordingFocus"), result);
    shadowOf(Looper.getMainLooper()).idle();
    verify(result, never()).success(any());

    deliver(
        tracker,
        convergenceResult(
            CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED, CaptureResult.CONTROL_AE_STATE_LOCKED));
    shadowOf(Looper.getMainLooper()).idle();

    verify(result).success(true);
  }

  private static TotalCaptureResult convergenceResult(int afState, int aeState) {
    final TotalCaptureResult captureResult = mock(TotalCaptureResult.class);
    when(captureResult.get(CaptureResult.CONTROL_AF_STATE)).thenReturn(afState);
    when(captureResult.get(CaptureResult.CONTROL_AE_STATE)).thenReturn(aeState);
    return captureResult;
  }

  @Test
  public void tearDown_answersPendingAppliedProfileAndFocusWaits() {
    bindRecordingCamera(30, focusMeteringSupportedCamera());
    final MethodChannel.Result applied = mock(MethodChannel.Result.class);
    controller.onMethodCall(appliedCall(), applied);
    final MethodChannel.Result focus = mock(MethodChannel.Result.class);
    controller.onMethodCall(cameraIdCall("waitForRecordingFocus"), focus);
    verify(applied, never()).error(any(), any(), any());
    verify(focus, never()).success(any());

    controller.tearDown();
    shadowOf(Looper.getMainLooper()).idle();

    verify(applied).error(eq("recordingQualityFailure"), anyString(), isNull());
    verify(focus).success(false);
    // The dropped poll callback must not answer a second time.
    shadowOf(Looper.getMainLooper()).idleFor(PAST_APPLIED_PROFILE_DEADLINE);
    verify(applied, never()).success(any());
  }

  @Test
  public void registerBoundCamera_forgetsCameraInfoOfSelectorsNoLongerBound() {
    final Preview preview = mock(Preview.class);
    controller.registerPreview(preview, CAMERA_ID);
    final CameraSelector firstSelector = mock(CameraSelector.class);
    final CameraSelector secondSelector = mock(CameraSelector.class);
    controller.registerCameraSelector(firstSelector, mock(CameraInfo.class));
    controller.registerBoundCamera(
        firstSelector, Collections.singletonList(preview), mockCamera());
    assertTrue(controller.hasSelectedCameraInfo(firstSelector));

    // A camera switch registers a new selector and binds it for the same camera id.
    controller.registerCameraSelector(secondSelector, mock(CameraInfo.class));
    controller.clearBoundCameras();
    controller.registerBoundCamera(
        secondSelector, Collections.singletonList(preview), mockCamera());

    assertFalse(controller.hasSelectedCameraInfo(firstSelector));
    assertTrue(controller.hasSelectedCameraInfo(secondSelector));
  }

  @Test
  public void registerBoundCamera_dropsTheTrackerMappingOfTheReplacedCameraControl() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        mock(RecordingQualityController.RecordingConvergenceTracker.class);
    final CameraControl initialCameraControl = mock(CameraControl.class);
    final CameraControl reboundCameraControl = mock(CameraControl.class);

    bindThenRebindPreviewOnly(
        mockVideoCapture(),
        tracker,
        mockCamera(initialCameraControl, mock(CameraInfo.class)),
        mockCamera(reboundCameraControl, mock(CameraInfo.class)));

    controller.onFocusMeteringStarted(initialCameraControl);
    verify(tracker, never()).reset();
    controller.onFocusMeteringStarted(reboundCameraControl);
    verify(tracker).reset();
  }

  /** Captures how and on which thread a method call was answered. */
  private static final class CapturingResult implements MethodChannel.Result {
    volatile String outcome;
    volatile Object value;
    volatile String errorCode;
    volatile Thread thread;

    @Override
    public void success(Object result) {
      value = result;
      answer("success");
    }

    @Override
    public void error(String code, String message, Object details) {
      errorCode = code;
      answer("error");
    }

    @Override
    public void notImplemented() {
      answer("notImplemented");
    }

    private void answer(String answeredOutcome) {
      thread = Thread.currentThread();
      outcome = answeredOutcome;
    }
  }

  /** Runs the main looper until {@code result} is answered by a background task. */
  private static void awaitResult(CapturingResult result) throws InterruptedException {
    final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
    while (result.outcome == null) {
      if (System.nanoTime() > deadline) {
        throw new AssertionError("The method call was not answered.");
      }
      shadowOf(Looper.getMainLooper()).idle();
      Thread.sleep(5);
    }
  }

  private CapturingResult inspect(RecordingMediaInspector inspector) throws Exception {
    final RecordingQualityController spyController = Mockito.spy(controller);
    Mockito.doReturn(inspector).when(spyController).createMediaInspector();
    final CapturingResult result = new CapturingResult();
    spyController.onMethodCall(
        new MethodCall("inspectRecordingMedia", Collections.singletonMap("path", "/a.mp4")),
        result);
    awaitResult(result);
    return result;
  }

  private static MethodCall capabilitiesCall() {
    return new MethodCall(
        "recordingQualityCapabilities", Collections.singletonMap("cameraName", "0"));
  }

  /** Makes ProcessCameraProvider resolve camera name "0" to {@code cameraInfo}. */
  private static AutoCloseable mockCameraLookup(CameraInfo cameraInfo) {
    final ProcessCameraProvider provider = mock(ProcessCameraProvider.class);
    when(provider.getAvailableCameraInfos()).thenReturn(Collections.singletonList(cameraInfo));
    final MockedStatic<ProcessCameraProvider> mockedProvider =
        Mockito.mockStatic(ProcessCameraProvider.class);
    mockedProvider
        .when(() -> ProcessCameraProvider.getInstance(any()))
        .thenReturn(Futures.immediateFuture(provider));
    final Camera2CameraInfo camera2CameraInfo = mock(Camera2CameraInfo.class);
    when(camera2CameraInfo.getCameraId()).thenReturn("0");
    // Camera2CameraInfo.from is resolved on the main looper, which runs on this thread.
    final MockedStatic<Camera2CameraInfo> mockedCamera2CameraInfo =
        Mockito.mockStatic(Camera2CameraInfo.class);
    mockedCamera2CameraInfo
        .when(() -> Camera2CameraInfo.from(cameraInfo))
        .thenReturn(camera2CameraInfo);
    return () -> {
      mockedCamera2CameraInfo.close();
      mockedProvider.close();
    };
  }

  private static Camera focusMeteringSupportedCamera() {
    final CameraInfo cameraInfo = mock(CameraInfo.class);
    when(cameraInfo.isFocusMeteringSupported(any())).thenReturn(true);
    return mockCamera(mock(CameraControl.class), cameraInfo);
  }

  private RecordingQualityController.RecordingConvergenceTracker bindRecordingCamera(
      int encoderFrameRate) {
    return bindRecordingCamera(encoderFrameRate, mockCamera());
  }

  @SuppressWarnings("unchecked")
  private RecordingQualityController.RecordingConvergenceTracker bindRecordingCamera(
      int encoderFrameRate, Camera camera) {
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
        mock(CameraSelector.class), Arrays.asList(boundPreview, boundVideoCapture), camera);
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
