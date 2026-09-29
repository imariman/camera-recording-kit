// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import CoreMedia
import UIKit

/// Factory block returning the capture device with the given unique ID, or nil when no such
/// device exists (for example a stale camera name).
/// Used in tests to inject a video capture device into DefaultCamera.
typealias VideoCaptureDeviceFactory = (_ cameraName: String) -> CaptureDevice?

/// Factory block returning the default audio capture device, or nil when there is none.
typealias AudioCaptureDeviceFactory = () -> CaptureDevice?

typealias CaptureSessionFactory = () -> CaptureSession

typealias AssetWriterFactory = (_ assetUrl: URL, _ fileType: AVFileType) throws -> AssetWriter

typealias InputPixelBufferAdaptorFactory = (
  _ input: AssetWriterInput, _ settings: [String: Any]?
) ->
  AssetWriterInputPixelBufferAdaptor

/// A configuration object that centralizes dependencies for `DefaultCamera`.
class CameraConfiguration {
  var mediaSettings: PlatformMediaSettings
  var mediaSettingsWrapper: FLTCamMediaSettingsAVWrapper
  var captureSessionQueue: DispatchQueue
  var videoCaptureSession: CaptureSession
  var audioCaptureSession: CaptureSession
  var videoCaptureDeviceFactory: VideoCaptureDeviceFactory
  let audioCaptureDeviceFactory: AudioCaptureDeviceFactory
  let captureDeviceInputFactory: CaptureDeviceInputFactory
  var assetWriterFactory: AssetWriterFactory
  var inputPixelBufferAdaptorFactory: InputPixelBufferAdaptorFactory
  var videoDimensionsConverter: VideoDimensionsConverter
  var deviceOrientationProvider: DeviceOrientationProvider
  let initialCameraName: String
  let recordingVideoCodec: RecordingQuality.VideoCodec
  var orientation: UIDeviceOrientation
  /// Orientation to assume while the device lies flat or reports `.unknown`, normally derived
  /// from the interface orientation when the camera was created.
  var fallbackOrientation: UIDeviceOrientation = .portrait

  init(
    mediaSettings: PlatformMediaSettings,
    mediaSettingsWrapper: FLTCamMediaSettingsAVWrapper,
    captureDeviceFactory: @escaping VideoCaptureDeviceFactory,
    audioCaptureDeviceFactory: @escaping AudioCaptureDeviceFactory,
    captureSessionFactory: @escaping CaptureSessionFactory,
    captureSessionQueue: DispatchQueue,
    captureDeviceInputFactory: CaptureDeviceInputFactory,
    initialCameraName: String,
    recordingVideoCodec: RecordingQuality.VideoCodec
  ) {
    self.mediaSettings = mediaSettings
    self.mediaSettingsWrapper = mediaSettingsWrapper
    self.videoCaptureDeviceFactory = captureDeviceFactory
    self.audioCaptureDeviceFactory = audioCaptureDeviceFactory
    self.captureSessionQueue = captureSessionQueue
    self.videoCaptureSession = captureSessionFactory()
    self.audioCaptureSession = captureSessionFactory()
    self.captureDeviceInputFactory = captureDeviceInputFactory
    self.initialCameraName = initialCameraName
    self.recordingVideoCodec = recordingVideoCodec
    self.orientation = UIDevice.current.orientation
    self.deviceOrientationProvider = DefaultDeviceOrientationProvider()

    self.videoDimensionsConverter = { format in
      return CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    self.assetWriterFactory = { url, fileType in
      return try AVAssetWriter(outputURL: url, fileType: fileType)
    }

    self.inputPixelBufferAdaptorFactory = { assetWriterInput, sourcePixelBufferAttributes in
      return AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: assetWriterInput.avInput,
        sourcePixelBufferAttributes: sourcePixelBufferAttributes
      )
    }
  }
}
