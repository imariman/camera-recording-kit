// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import android.net.Uri;
import androidx.camera.video.OutputResults;
import androidx.camera.video.VideoRecordEvent;
import java.io.File;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class VideoRecordEventFinalizeTest {
  @Test
  public void registrar_providesFinalizeProxyApi() {
    assertTrue(
        new TestProxyApiRegistrar().getPigeonApiVideoRecordEventFinalize()
            instanceof VideoRecordEventFinalizeProxyApi);
  }

  @Test
  public void error_returnsFinalizeErrorCode() {
    final PigeonApiVideoRecordEventFinalize api =
        new TestProxyApiRegistrar().getPigeonApiVideoRecordEventFinalize();

    assertEquals(
        VideoRecordEvent.Finalize.ERROR_NONE,
        api.error(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE, Uri.EMPTY)));
    assertEquals(
        VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE,
        api.error(
            finalizeEvent(VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE, Uri.EMPTY)));
  }

  @Test
  public void outputUri_returnsFileUriOfTheRecording() {
    final PigeonApiVideoRecordEventFinalize api =
        new TestProxyApiRegistrar().getPigeonApiVideoRecordEventFinalize();
    final Uri fileUri = Uri.fromFile(new File("/data/cache/REC123.mp4"));

    assertEquals(
        "file:///data/cache/REC123.mp4",
        api.outputUri(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NONE, fileUri)));
  }

  @Test
  public void outputUri_returnsNullForEmptyUri() {
    final PigeonApiVideoRecordEventFinalize api =
        new TestProxyApiRegistrar().getPigeonApiVideoRecordEventFinalize();

    assertNull(
        api.outputUri(finalizeEvent(VideoRecordEvent.Finalize.ERROR_NO_VALID_DATA, Uri.EMPTY)));
  }

  private static VideoRecordEvent.Finalize finalizeEvent(int error, Uri outputUri) {
    final OutputResults outputResults = mock(OutputResults.class);
    when(outputResults.getOutputUri()).thenReturn(outputUri);
    final VideoRecordEvent.Finalize event = mock(VideoRecordEvent.Finalize.class);
    when(event.getError()).thenReturn(error);
    when(event.getOutputResults()).thenReturn(outputResults);
    return event;
  }
}
