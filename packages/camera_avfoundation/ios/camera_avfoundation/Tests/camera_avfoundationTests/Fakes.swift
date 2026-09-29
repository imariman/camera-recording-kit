// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// 'btp2' (kCVPixelFormatType_96VersatileBayerPacked12).
let btp2SubType: FourCharCode = 1_651_798_066
/// '420v' (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange).
let yuvVideoRangeSubType: FourCharCode = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
/// '420f' (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange).
let yuvFullRangeSubType: FourCharCode = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

/// Reads the dimensions the fake formats were created with.
let fakeDimensionsConverter: VideoDimensionsConverter = { format in
  CMVideoFormatDescriptionGetDimensions(format.formatDescription)
}

final class FakeFrameRateRange: NSObject, FrameRateRange {
  let minFrameRate: Float64
  let maxFrameRate: Float64

  init(_ minFrameRate: Float64, _ maxFrameRate: Float64) {
    self.minFrameRate = minFrameRate
    self.maxFrameRate = maxFrameRate
  }
}

final class FakeCaptureDeviceFormat: NSObject, CaptureDeviceFormat {
  let formatDescription: CMFormatDescription
  let flutterVideoSupportedFrameRateRanges: [FrameRateRange]

  init(
    width: Int32,
    height: Int32,
    subType: FourCharCode = yuvVideoRangeSubType,
    frameRates: [(Float64, Float64)] = [(1, 30)]
  ) {
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: subType,
      width: width,
      height: height,
      extensions: nil,
      formatDescriptionOut: &description)
    precondition(status == noErr && description != nil, "Could not create a format description")
    formatDescription = description!
    flutterVideoSupportedFrameRateRanges = frameRates.map { FakeFrameRateRange($0.0, $0.1) }
  }

  var avFormat: AVCaptureDevice.Format {
    fatalError("Fake formats have no AVCaptureDevice.Format")
  }
}

/// A capture device backed by fake formats. Only the members used by the code under test have
/// meaningful values.
final class FakeCaptureDevice: NSObject, CaptureDevice {
  var flutterActiveFormat: CaptureDeviceFormat
  var flutterFormats: [CaptureDeviceFormat]
  var supportedFocusModes: Set<AVCaptureDevice.FocusMode> = [.locked, .autoFocus]
  var supportedExposureModes: Set<AVCaptureDevice.ExposureMode> = [.locked, .autoExpose]

  init(formats: [FakeCaptureDeviceFormat], activeFormat: FakeCaptureDeviceFormat? = nil) {
    flutterFormats = formats
    flutterActiveFormat = activeFormat ?? formats[0]
  }

  var avDevice: AVCaptureDevice { fatalError("Fake devices have no AVCaptureDevice") }
  var uniqueID: String { "fake-camera" }
  var position: AVCaptureDevice.Position { .back }
  var deviceType: AVCaptureDevice.DeviceType { .builtInWideAngleCamera }

  var hasFlash: Bool { false }
  var hasTorch: Bool { false }
  var isTorchAvailable: Bool { false }
  var torchMode: AVCaptureDevice.TorchMode = .off
  func isFlashModeSupported(_ mode: AVCaptureDevice.FlashMode) -> Bool { false }

  var isFocusPointOfInterestSupported: Bool { true }
  func isFocusModeSupported(_ mode: AVCaptureDevice.FocusMode) -> Bool {
    supportedFocusModes.contains(mode)
  }
  var isAdjustingFocus: Bool { false }
  var focusMode: AVCaptureDevice.FocusMode = .locked
  var focusPointOfInterest: CGPoint = .zero

  var isExposurePointOfInterestSupported: Bool { true }
  var exposureMode: AVCaptureDevice.ExposureMode = .locked
  var exposurePointOfInterest: CGPoint = .zero
  var minExposureTargetBias: Float { -2 }
  var maxExposureTargetBias: Float { 2 }
  func setExposureTargetBias(_ bias: Float, completionHandler handler: ((CMTime) -> Void)?) {}
  func isExposureModeSupported(_ mode: AVCaptureDevice.ExposureMode) -> Bool {
    supportedExposureModes.contains(mode)
  }
  var isAdjustingExposure: Bool { false }

  var maxAvailableVideoZoomFactor: CGFloat { 1 }
  var minAvailableVideoZoomFactor: CGFloat { 1 }
  var videoZoomFactor: CGFloat = 1

  func isVideoStabilizationModeSupported(_ videoStabilizationMode: AVCaptureVideoStabilizationMode)
    -> Bool
  {
    false
  }

  var lensAperture: Float { 1.8 }
  var exposureDuration: CMTime { .zero }
  var iso: Float { 100 }

  func lockForConfiguration() throws {}
  func unlockForConfiguration() {}

  var activeVideoMinFrameDuration: CMTime = .invalid
  var activeVideoMaxFrameDuration: CMTime = .invalid
}
