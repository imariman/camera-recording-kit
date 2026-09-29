// Copyright 2026 Teleprompter Studio. All rights reserved.

import AVFoundation
import XCTest

@testable import camera_avfoundation

final class FormatUtilsTests: XCTestCase {
  private let fullHD = CMVideoDimensions(width: 1920, height: 1080)

  func testIsSelectableRejectsBtp2AndSquareFormats() {
    let regular = FakeCaptureDeviceFormat(width: 1920, height: 1080)
    let bayer = FakeCaptureDeviceFormat(width: 1920, height: 1080, subType: btp2SubType)
    let square = FakeCaptureDeviceFormat(width: 1080, height: 1080)

    XCTAssertTrue(FormatUtils.isSelectable(regular, videoDimensionsConverter: fakeDimensionsConverter))
    XCTAssertFalse(FormatUtils.isSelectable(bayer, videoDimensionsConverter: fakeDimensionsConverter))
    XCTAssertFalse(FormatUtils.isSelectable(square, videoDimensionsConverter: fakeDimensionsConverter))
  }

  func testFindExactFormatPrefersTheActiveSubType() {
    let active = FakeCaptureDeviceFormat(width: 1280, height: 720, subType: yuvFullRangeSubType)
    let videoRange = FakeCaptureDeviceFormat(
      width: 1920, height: 1080, subType: yuvVideoRangeSubType, frameRates: [(1, 60)])
    let fullRange = FakeCaptureDeviceFormat(
      width: 1920, height: 1080, subType: yuvFullRangeSubType, frameRates: [(1, 60)])
    let device = FakeCaptureDevice(formats: [active, videoRange, fullRange], activeFormat: active)

    let format = FormatUtils.findExactFormat(
      for: device, targetResolution: fullHD, targetFrameRate: 60,
      videoDimensionsConverter: fakeDimensionsConverter)

    XCTAssertTrue(format === fullRange)
  }

  func testFindExactFormatFallsBackToAnotherSubType() {
    let active = FakeCaptureDeviceFormat(width: 1280, height: 720, subType: yuvFullRangeSubType)
    let videoRange = FakeCaptureDeviceFormat(
      width: 1920, height: 1080, subType: yuvVideoRangeSubType, frameRates: [(1, 30)])
    let device = FakeCaptureDevice(formats: [active, videoRange], activeFormat: active)

    let format = FormatUtils.findExactFormat(
      for: device, targetResolution: fullHD, targetFrameRate: 30,
      videoDimensionsConverter: fakeDimensionsConverter)

    XCTAssertTrue(format === videoRange)
  }

  func testFindExactFormatNeverSubstitutesTheFrameRate() {
    let format30 = FakeCaptureDeviceFormat(width: 1920, height: 1080, frameRates: [(1, 30)])
    let device = FakeCaptureDevice(formats: [format30])

    XCTAssertNil(
      FormatUtils.findExactFormat(
        for: device, targetResolution: fullHD, targetFrameRate: 60,
        videoDimensionsConverter: fakeDimensionsConverter))
  }

  func testFindExactFormatSkipsBtp2EvenInTheActiveSubType() {
    let activeBayer = FakeCaptureDeviceFormat(
      width: 1280, height: 720, subType: btp2SubType, frameRates: [(1, 30)])
    let bayer = FakeCaptureDeviceFormat(
      width: 1920, height: 1080, subType: btp2SubType, frameRates: [(1, 60)])
    let device = FakeCaptureDevice(formats: [activeBayer, bayer], activeFormat: activeBayer)

    XCTAssertNil(
      FormatUtils.findExactFormat(
        for: device, targetResolution: fullHD, targetFrameRate: 60,
        videoDimensionsConverter: fakeDimensionsConverter))

    let yuv = FakeCaptureDeviceFormat(width: 1920, height: 1080, frameRates: [(1, 60)])
    device.flutterFormats = [activeBayer, bayer, yuv]
    let format = FormatUtils.findExactFormat(
      for: device, targetResolution: fullHD, targetFrameRate: 60,
      videoDimensionsConverter: fakeDimensionsConverter)
    XCTAssertTrue(format === yuv)
  }

  func testSupportsFrameRateUsesInclusiveRanges() {
    let format = FakeCaptureDeviceFormat(width: 1920, height: 1080, frameRates: [(1, 30), (60, 60)])

    XCTAssertTrue(FormatUtils.supports(frameRate: 30, on: format))
    XCTAssertTrue(FormatUtils.supports(frameRate: 60, on: format))
    XCTAssertFalse(FormatUtils.supports(frameRate: 45, on: format))
  }
}
