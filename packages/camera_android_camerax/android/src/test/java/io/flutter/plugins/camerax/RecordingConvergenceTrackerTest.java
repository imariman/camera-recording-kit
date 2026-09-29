// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.TotalCaptureResult;
import android.util.Range;
import io.flutter.plugin.common.MethodChannel;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

// Robolectric provides real CaptureResult keys and Range values; the plain
// android.jar stubs make every CaptureResult.Key null and Range a no-op.
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
public class RecordingConvergenceTrackerTest {
  @Test
  public void waitForConvergence_requiresFocusAndExposureFromCaptureResult() throws Exception {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        new RecordingQualityController.RecordingConvergenceTracker();
    final MethodChannel.Result channelResult = mock(MethodChannel.Result.class);
    final ScheduledExecutorService timeoutExecutor = Executors.newSingleThreadScheduledExecutor();
    final TotalCaptureResult captureResult = mock(TotalCaptureResult.class);
    when(captureResult.get(CaptureResult.CONTROL_AF_STATE))
        .thenReturn(CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED);
    when(captureResult.get(CaptureResult.CONTROL_AE_STATE))
        .thenReturn(CaptureResult.CONTROL_AE_STATE_SEARCHING);

    try {
      tracker.waitForConvergence(channelResult, Runnable::run, timeoutExecutor, 1L);
      tracker.onCaptureCompleted(
          mock(CameraCaptureSession.class), mock(CaptureRequest.class), captureResult);
      verify(channelResult, never()).success(true);

      when(captureResult.get(CaptureResult.CONTROL_AE_STATE))
          .thenReturn(CaptureResult.CONTROL_AE_STATE_CONVERGED);
      tracker.onCaptureCompleted(
          mock(CameraCaptureSession.class), mock(CaptureRequest.class), captureResult);

      verify(channelResult).success(true);
    } finally {
      timeoutExecutor.shutdownNow();
      timeoutExecutor.awaitTermination(1L, TimeUnit.SECONDS);
    }
  }

  @Test
  public void resetPreventsStaleConvergenceFromCompletingNextWait() throws Exception {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        new RecordingQualityController.RecordingConvergenceTracker();
    final TotalCaptureResult captureResult = mock(TotalCaptureResult.class);
    when(captureResult.get(CaptureResult.CONTROL_AF_STATE))
        .thenReturn(CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED);
    when(captureResult.get(CaptureResult.CONTROL_AE_STATE))
        .thenReturn(CaptureResult.CONTROL_AE_STATE_CONVERGED);
    tracker.onCaptureCompleted(
        mock(CameraCaptureSession.class), mock(CaptureRequest.class), captureResult);
    tracker.reset();

    final MethodChannel.Result channelResult = mock(MethodChannel.Result.class);
    final ScheduledExecutorService timeoutExecutor = Executors.newSingleThreadScheduledExecutor();
    try {
      tracker.waitForConvergence(channelResult, Runnable::run, timeoutExecutor, 0L);
      timeoutExecutor.shutdown();
      timeoutExecutor.awaitTermination(1L, TimeUnit.SECONDS);

      verify(channelResult).success(false);
      verify(channelResult, never()).success(true);
    } finally {
      timeoutExecutor.shutdownNow();
    }
  }

  @Test
  public void onCaptureCompleted_recordsLatestCaptureCadenceAndStabilizationMode() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        new RecordingQualityController.RecordingConvergenceTracker();
    assertNull(tracker.getObservedAeTargetFpsRange());
    assertNull(tracker.getObservedVideoStabilizationMode());

    deliver(
        tracker,
        captureResult(new Range<>(30, 30), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF));
    assertEquals(new Range<>(30, 30), tracker.getObservedAeTargetFpsRange());
    assertEquals(
        Integer.valueOf(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_OFF),
        tracker.getObservedVideoStabilizationMode());

    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON));
    assertEquals(new Range<>(60, 60), tracker.getObservedAeTargetFpsRange());
    assertEquals(
        Integer.valueOf(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON),
        tracker.getObservedVideoStabilizationMode());
  }

  @Test
  public void onCaptureCompleted_keepsLastReportedValuesWhenResultOmitsKeys() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        new RecordingQualityController.RecordingConvergenceTracker();
    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON));

    deliver(tracker, captureResult(null, null));

    assertEquals(new Range<>(60, 60), tracker.getObservedAeTargetFpsRange());
    assertEquals(
        Integer.valueOf(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON),
        tracker.getObservedVideoStabilizationMode());
  }

  @Test
  public void focusResetKeepsReadbackButReadbackResetClearsIt() {
    final RecordingQualityController.RecordingConvergenceTracker tracker =
        new RecordingQualityController.RecordingConvergenceTracker();
    deliver(
        tracker,
        captureResult(new Range<>(60, 60), CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON));

    tracker.reset();
    assertEquals(new Range<>(60, 60), tracker.getObservedAeTargetFpsRange());
    assertEquals(
        Integer.valueOf(CaptureResult.CONTROL_VIDEO_STABILIZATION_MODE_ON),
        tracker.getObservedVideoStabilizationMode());

    tracker.resetCaptureResultReadback();
    assertNull(tracker.getObservedAeTargetFpsRange());
    assertNull(tracker.getObservedVideoStabilizationMode());
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
}
