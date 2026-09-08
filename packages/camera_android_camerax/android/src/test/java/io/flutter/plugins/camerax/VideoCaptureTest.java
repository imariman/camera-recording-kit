// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import android.util.Range;
import androidx.camera.video.Recorder;
import androidx.camera.video.VideoCapture;
import androidx.camera.video.VideoOutput;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class VideoCaptureTest {
  @Test
  public void withOutput_createsVideoCaptureWithVideoOutputAndExactTargetFrameRate() {
    final PigeonApiVideoCapture api = new TestProxyApiRegistrar().getPigeonApiVideoCapture();

    final VideoOutput videoOutput = mock(VideoOutput.class);
    final Range<Integer> targetFpsRange = new Range<>(30, 30);

    final VideoCapture<?> videoCapture = api.withOutput(videoOutput, targetFpsRange);

    assertEquals(videoOutput, videoCapture.getOutput());
    assertEquals(targetFpsRange, videoCapture.getTargetFrameRate());
  }

  @Test
  public void withOutput_setsRecorderEncodingFrameRateForFixedTarget() {
    final PigeonApiVideoCapture api = new TestProxyApiRegistrar().getPigeonApiVideoCapture();
    final Recorder recorder = new Recorder.Builder().build();

    api.withOutput(recorder, new Range<Integer>(60, 60));

    assertEquals(60, recorder.getVideoEncodingFrameRate());
  }

  @SuppressWarnings("unchecked")
  @Test
  public void getOutput_returnsAssociatedRecorder() {
    final PigeonApiVideoCapture api = new TestProxyApiRegistrar().getPigeonApiVideoCapture();

    final VideoCapture<VideoOutput> instance = mock(VideoCapture.class);
    final VideoOutput value = mock(VideoOutput.class);
    when(instance.getOutput()).thenReturn(value);

    assertEquals(value, api.getOutput(instance));
  }

  @SuppressWarnings("unchecked")
  @Test
  public void setTargetRotation_makesCallToSetTargetRotation() {
    final PigeonApiVideoCapture api = new TestProxyApiRegistrar().getPigeonApiVideoCapture();

    final VideoCapture<VideoOutput> instance = mock(VideoCapture.class);
    final long rotation = 0;
    api.setTargetRotation(instance, rotation);

    verify(instance).setTargetRotation((int) rotation);
  }
}
