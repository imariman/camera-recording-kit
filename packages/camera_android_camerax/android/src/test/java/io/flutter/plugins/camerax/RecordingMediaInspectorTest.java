// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.when;

import android.media.MediaExtractor;
import android.media.MediaFormat;
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

  @Test
  public void inspect_reportsContainerMimeTypeAndTrackCodecsString() throws Exception {
    final MediaFormat audioFormat = MediaFormat.createAudioFormat("audio/mp4a-latm", 48_000, 2);
    final MediaFormat videoFormat = MediaFormat.createVideoFormat("video/avc", 1920, 1080);
    videoFormat.setString(MediaFormat.KEY_CODECS_STRING, "avc1.640028");

    final Map<String, Object> metadata =
        inspect("recording.mp4", defaultRetrieverMetadata(), audioFormat, videoFormat);

    assertEquals("video/mp4", metadata.get("mimeType"));
    assertEquals("avc1.640028", metadata.get("codec"));
    assertEquals(1920, metadata.get("width"));
    assertEquals(1080, metadata.get("height"));
  }

  @Test
  public void inspect_fallsBackToTrackMimeSubtypeAndTrackSizeWithoutRetrieverValues()
      throws Exception {
    final MediaFormat videoFormat = MediaFormat.createVideoFormat("video/hevc", 3840, 2160);
    videoFormat.setInteger(MediaFormat.KEY_FRAME_RATE, 60);
    final Map<Integer, String> retrieverMetadata = new HashMap<>();
    retrieverMetadata.put(
        MediaMetadataRetriever.METADATA_KEY_DURATION, String.valueOf(DURATION_MILLISECONDS));

    final Map<String, Object> metadata = inspect("recording.mp4", retrieverMetadata, videoFormat);

    // The container type comes from the extension, as on iOS and macOS, not from the track.
    assertEquals("video/mp4", metadata.get("mimeType"));
    assertEquals("hevc", metadata.get("codec"));
    assertEquals(3840, metadata.get("width"));
    assertEquals(2160, metadata.get("height"));
    assertEquals(60, metadata.get("fps"));
    assertEquals("nominal", metadata.get("fpsSource"));
  }

  @Test
  public void inspect_reportsNoCodecInsteadOfContainerSubtypeWithoutVideoTrack() throws Exception {
    final Map<String, Object> metadata = inspect("recording.mp4", defaultRetrieverMetadata());

    assertEquals("video/mp4", metadata.get("mimeType"));
    assertNull(metadata.get("codec"));
  }

  @Test
  public void inspect_derivesQuickTimeMimeTypeFromExtension() throws Exception {
    final Map<Integer, String> retrieverMetadata = defaultRetrieverMetadata();
    retrieverMetadata.remove(MediaMetadataRetriever.METADATA_KEY_MIMETYPE);

    final Map<String, Object> metadata = inspect("recording.mov", retrieverMetadata);

    assertEquals("video/quicktime", metadata.get("mimeType"));
  }

  @Test
  public void inspect_rejectsMissingFile() {
    final RecordingMediaInspector.MediaInspectionException exception =
        assertThrows(
            RecordingMediaInspector.MediaInspectionException.class,
            () -> new RecordingMediaInspector().inspect(new File("/does/not/exist.mp4")));

    assertEquals("recordingMediaNotFound", exception.code);
  }

  private Map<String, Object> inspectWithContainerBitrate(String containerBitrate)
      throws IOException, RecordingMediaInspector.MediaInspectionException {
    final Map<Integer, String> retrieverMetadata = defaultRetrieverMetadata();
    if (containerBitrate != null) {
      retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_BITRATE, containerBitrate);
    }
    return inspect("recording.mp4", retrieverMetadata);
  }

  private static Map<Integer, String> defaultRetrieverMetadata() {
    final Map<Integer, String> retrieverMetadata = new HashMap<>();
    retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH, "1920");
    retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT, "1080");
    retrieverMetadata.put(
        MediaMetadataRetriever.METADATA_KEY_DURATION, String.valueOf(DURATION_MILLISECONDS));
    retrieverMetadata.put(MediaMetadataRetriever.METADATA_KEY_MIMETYPE, "video/mp4");
    return retrieverMetadata;
  }

  /**
   * Inspects a file named {@code fileName} with a mocked {@link MediaMetadataRetriever} returning
   * {@code retrieverMetadata} and a mocked {@link MediaExtractor} exposing {@code trackFormats}.
   */
  private Map<String, Object> inspect(
      String fileName, Map<Integer, String> retrieverMetadata, MediaFormat... trackFormats)
      throws IOException, RecordingMediaInspector.MediaInspectionException {
    final File file = temporaryFolder.newFile(fileName);
    try (FileOutputStream output = new FileOutputStream(file)) {
      output.write(new byte[FILE_SIZE_BYTES]);
    }

    try (MockedConstruction<MediaMetadataRetriever> ignoredRetriever =
            Mockito.mockConstruction(
                MediaMetadataRetriever.class,
                (mock, context) ->
                    when(mock.extractMetadata(anyInt()))
                        .thenAnswer(
                            invocation -> retrieverMetadata.get(invocation.<Integer>getArgument(0))));
        MockedConstruction<MediaExtractor> ignoredExtractor =
            Mockito.mockConstruction(
                MediaExtractor.class,
                (mock, context) -> {
                  when(mock.getTrackCount()).thenReturn(trackFormats.length);
                  for (int index = 0; index < trackFormats.length; index++) {
                    when(mock.getTrackFormat(index)).thenReturn(trackFormats[index]);
                  }
                })) {
      return new RecordingMediaInspector().inspect(file);
    }
  }
}
