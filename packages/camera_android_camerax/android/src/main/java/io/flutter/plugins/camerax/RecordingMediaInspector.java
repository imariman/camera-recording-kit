// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

package io.flutter.plugins.camerax;

import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import java.io.File;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/** Reads finalized recording container metadata without decoding media samples. */
final class RecordingMediaInspector {
  @NonNull
  Map<String, Object> inspect(@NonNull File file) throws MediaInspectionException {
    if (!file.isFile() || !file.canRead()) {
      throw new MediaInspectionException(
          "recordingMediaNotFound", "The finalized recording file is not readable: " + file, null);
    }

    final MediaMetadataRetriever retriever = new MediaMetadataRetriever();
    final MediaExtractor extractor = new MediaExtractor();
    try {
      retriever.setDataSource(file.getAbsolutePath());
      extractor.setDataSource(file.getAbsolutePath());

      final MediaFormat videoFormat = findVideoFormat(extractor);
      final Integer width =
          firstInteger(
              extractInteger(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
              getInteger(videoFormat, MediaFormat.KEY_WIDTH));
      final Integer height =
          firstInteger(
              extractInteger(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
              getInteger(videoFormat, MediaFormat.KEY_HEIGHT));
      if (width == null || height == null || width <= 0 || height <= 0) {
        throw new MediaInspectionException(
            "recordingMediaInvalid",
            "The finalized recording does not contain a readable video track size.",
            null);
      }

      final Integer durationMilliseconds =
          extractInteger(retriever, MediaMetadataRetriever.METADATA_KEY_DURATION);
      final Integer rotationDegrees =
          firstInteger(
              extractInteger(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION),
              getInteger(videoFormat, MediaFormat.KEY_ROTATION));
      final String mimeType =
          firstString(
              getString(videoFormat, MediaFormat.KEY_MIME),
              retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE));

      Number fps = null;
      String fpsSource = "nominal";
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && durationMilliseconds != null) {
        final Integer frameCount =
            extractInteger(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT);
        if (frameCount != null && frameCount > 0 && durationMilliseconds > 0) {
          fps = frameCount * 1000.0 / durationMilliseconds;
          fpsSource = "measured";
        }
      }
      if (fps == null) {
        fps = getNumber(videoFormat, MediaFormat.KEY_FRAME_RATE);
        if (fps == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
          fps =
              extractDouble(
                  retriever, MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE);
        }
      }

      Integer bitrate = null;
      String bitrateSource = "estimated";
      final Integer measuredBitrate =
          extractInteger(retriever, MediaMetadataRetriever.METADATA_KEY_BITRATE);
      if (measuredBitrate != null && measuredBitrate > 0) {
        bitrate = measuredBitrate;
        bitrateSource = "measured";
      } else if (durationMilliseconds != null && durationMilliseconds > 0 && file.length() > 0) {
        final long estimatedBitrate = file.length() * 8_000L / durationMilliseconds;
        bitrate = estimatedBitrate > Integer.MAX_VALUE ? Integer.MAX_VALUE : (int) estimatedBitrate;
      }

      final Map<String, Object> metadata = new HashMap<>();
      metadata.put("width", width);
      metadata.put("height", height);
      metadata.put("durationMilliseconds", durationMilliseconds);
      metadata.put("rotationDegrees", rotationDegrees);
      metadata.put("fps", fps);
      metadata.put("fpsSource", fpsSource);
      metadata.put("bitrate", bitrate);
      metadata.put("bitrateSource", bitrateSource);
      metadata.put("codec", codecName(videoFormat, mimeType));
      metadata.put("mimeType", mimeType);
      metadata.put("fileSizeBytes", file.length());
      return metadata;
    } catch (IOException | IllegalArgumentException | IllegalStateException exception) {
      throw new MediaInspectionException(
          "recordingMediaInvalid",
          "The finalized recording metadata could not be read.",
          exception);
    } finally {
      extractor.release();
      try {
        retriever.release();
      } catch (IOException ignored) {
        // Metadata has already been copied into the result map.
      }
    }
  }

  @Nullable
  private MediaFormat findVideoFormat(@NonNull MediaExtractor extractor) {
    for (int index = 0; index < extractor.getTrackCount(); index++) {
      final MediaFormat format = extractor.getTrackFormat(index);
      final String mimeType = getString(format, MediaFormat.KEY_MIME);
      if (mimeType != null && mimeType.startsWith("video/")) {
        return format;
      }
    }
    return null;
  }

  @Nullable
  private String codecName(@Nullable MediaFormat format, @Nullable String mimeType) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      final String codecs = getString(format, MediaFormat.KEY_CODECS_STRING);
      if (codecs != null && !codecs.isEmpty()) {
        return codecs;
      }
    }
    if (mimeType == null) {
      return null;
    }
    final int separator = mimeType.indexOf('/');
    return separator >= 0 && separator + 1 < mimeType.length()
        ? mimeType.substring(separator + 1)
        : mimeType;
  }

  @Nullable
  private Integer extractInteger(@NonNull MediaMetadataRetriever retriever, int key) {
    final String value = retriever.extractMetadata(key);
    if (value == null) {
      return null;
    }
    try {
      return Integer.valueOf(value);
    } catch (NumberFormatException ignored) {
      return null;
    }
  }

  @Nullable
  private Double extractDouble(@NonNull MediaMetadataRetriever retriever, int key) {
    final String value = retriever.extractMetadata(key);
    if (value == null) {
      return null;
    }
    try {
      return Double.valueOf(value);
    } catch (NumberFormatException ignored) {
      return null;
    }
  }

  @Nullable
  private Integer getInteger(@Nullable MediaFormat format, @NonNull String key) {
    if (format == null || !format.containsKey(key)) {
      return null;
    }
    try {
      return format.getInteger(key);
    } catch (ClassCastException | NullPointerException ignored) {
      return null;
    }
  }

  @Nullable
  private Number getNumber(@Nullable MediaFormat format, @NonNull String key) {
    if (format == null || !format.containsKey(key)) {
      return null;
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      return format.getNumber(key);
    }
    try {
      return format.getInteger(key);
    } catch (ClassCastException | NullPointerException ignored) {
      try {
        return format.getFloat(key);
      } catch (ClassCastException | NullPointerException alsoIgnored) {
        return null;
      }
    }
  }

  @Nullable
  private String getString(@Nullable MediaFormat format, @NonNull String key) {
    if (format == null || !format.containsKey(key)) {
      return null;
    }
    try {
      return format.getString(key);
    } catch (ClassCastException | NullPointerException ignored) {
      return null;
    }
  }

  @Nullable
  private Integer firstInteger(@Nullable Integer first, @Nullable Integer second) {
    return first == null ? second : first;
  }

  @Nullable
  private String firstString(@Nullable String first, @Nullable String second) {
    return first == null ? second : first;
  }

  static final class MediaInspectionException extends Exception {
    @NonNull final String code;

    MediaInspectionException(
        @NonNull String code,
        @NonNull String message,
        @Nullable Throwable cause) {
      super(message, cause);
      this.code = code;
    }
  }
}
