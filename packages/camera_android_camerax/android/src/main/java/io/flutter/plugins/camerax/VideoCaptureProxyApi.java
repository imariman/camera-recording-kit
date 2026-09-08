// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.util.Range;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.camera.camera2.interop.Camera2Interop;
import androidx.camera.camera2.interop.ExperimentalCamera2Interop;
import androidx.camera.video.Recorder;
import androidx.camera.video.VideoCapture;
import androidx.camera.video.VideoOutput;

/**
 * ProxyApi implementation for {@link VideoCapture}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class VideoCaptureProxyApi extends PigeonApiVideoCapture {
  VideoCaptureProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  // Range<?> is defined as Range<Integer> in pigeon.
  @SuppressWarnings("unchecked")
  @OptIn(markerClass = ExperimentalCamera2Interop.class)
  @NonNull
  @Override
  public VideoCapture<?> withOutput(
      @NonNull VideoOutput videoOutput, @Nullable Range<?> targetFpsRange) {
    VideoCapture.Builder<VideoOutput> builder = new VideoCapture.Builder<>(videoOutput);
    final RecordingQualityController.RecordingConvergenceTracker convergenceTracker =
        getPigeonRegistrar().getRecordingQualityController().createConvergenceTracker();
    new Camera2Interop.Extender<>(builder).setSessionCaptureCallback(convergenceTracker);

    if (targetFpsRange != null) {
      final Range<Integer> fpsRange = (Range<Integer>) targetFpsRange;
      builder.setTargetFrameRate(fpsRange);
      if (videoOutput instanceof Recorder && fpsRange.getLower().equals(fpsRange.getUpper())) {
        // Keep CameraX capture cadence and the encoder's declared frame rate aligned.
        ((Recorder) videoOutput).setVideoEncodingFrameRate(fpsRange.getLower());
      }
    }

    final VideoCapture<?> videoCapture = builder.build();
    getPigeonRegistrar()
        .getRecordingQualityController()
        .registerVideoCapture(videoCapture, convergenceTracker);
    return videoCapture;
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @NonNull
  @Override
  public VideoOutput getOutput(VideoCapture<?> pigeonInstance) {
    return pigeonInstance.getOutput();
  }

  @Override
  public void setTargetRotation(VideoCapture<?> pigeonInstance, long rotation) {
    pigeonInstance.setTargetRotation((int) rotation);
  }
}
