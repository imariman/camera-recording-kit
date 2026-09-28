// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.when;

import android.media.MediaExtractor;
import android.media.MediaMetadataRetriever;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.mockito.MockedConstruction;
import org.mockito.Mockito;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
public class RecordingMediaInspectorTest {
  private static final int FILE_SIZE_BYTES = 2_000;
  private static final int DURATION_MILLISECONDS = 1_000;
  private static final int ESTIMATED_BITRATE = FILE_SIZE_BYTES * 8_000 / DURATION_MILLISECONDS;

  @Rule public TemporaryFolder temporaryFolder = new TemporaryFolder();

  @Test
  public void inspect_prefersMeasuredContainerBitrateWhenPresent() throws Exception {
    final Map<String, Object> metadata = inspectWithContainerBitrate("12000");

    assertEquals(12_000, metadata.get("bitrate"));
    assertEquals("measured", metadata.get("bitrateSource"));
  }

  @Test
  public void inspect_fallsBackToFileSizeEstimateWhenContainerBitrateIsMissing() throws Exception {
    final Map<String, Object> metadata = inspectWithContainerBitrate(null);

    assertEquals(ESTIMATED_BITRATE, metadata.get("bitrate"));
    assertEquals("estimated", metadata.get("bitrateSource"));
  }

  @Test
  public void inspect_fallsBackToFileSizeEstimateWhenContainerBitrateIsNotPositive()
      throws Exception {
    final Map<String, Object> metadata = inspectWithContainerBitrate("0");

    assertEquals(ESTIMATED_BITRATE, metadata.get("bitrate"));
    assertEquals("estimated", metadata.get("bitrateSource"));
  }

  private Map<String, Object> inspectWithContainerBitrate(String containerBitrate)
      throws IOException, RecordingMediaInspector.MediaInspectionException {
    final File file = temporaryFolder.newFile("recording.mp4");
    try (FileOutputStream output = new FileOutputStream(file)) {
      output.write(new byte[FILE_SIZE_BYTES]);
    }

    final Map<Integer, String> retrieverMetadata = new HashMap<>();
    retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH, "1920");
    retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT, "1080");
    retrieverMetadata.put(
        MediaMetadataRetriever.METADATA_KEY_DURATION, String.valueOf(DURATION_MILLISECONDS));
    retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_MIMETYPE, "video/mp4");
    if (containerBitrate != null) {
      retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_BITRATE, containerBitrate);
    }

    try (MockedConstruction<MediaMetadataRetriever> ignoredRetriever =
            Mockito.mockConstruction(
                MediaMetadataRetriever.class,
                (mock, context) ->
                    when(mock.extractMetadata(anyInt()))
                        .thenAnswer(
                            invocation -> retrieverMetadata.get(invocation.<Integer>getArgument(0))));
        MockedConstruction<MediaExtractor> ignoredExtractor =
            Mockito.mockConstruction(MediaExtractor.class)) {
      return new RecordingMediaInspector().inspect(file);
    }
  }
}
