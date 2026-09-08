// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.TotalCaptureResult;
import io.flutter.plugin.common.MethodChannel;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.junit.Test;

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
}
