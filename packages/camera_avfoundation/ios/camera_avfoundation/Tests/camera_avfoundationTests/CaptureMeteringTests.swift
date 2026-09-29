// Copyright 2026 Teleprompter Studio. All rights reserved.

import AVFoundation
import UIKit
import XCTest

@testable import camera_avfoundation

final class CaptureMeteringTests: XCTestCase {
  private let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)

  private func after(_ milliseconds: Int) -> DispatchTime {
    return start + .milliseconds(milliseconds)
  }

  // MARK: Metering settle

  func testSettledWithoutAPendingMeteringChange() {
    XCTAssertTrue(
      CaptureMetering.hasSettled(lastChange: nil, adjustmentObservedAt: nil, now: start))
  }

  func testNotSettledRightAfterAChangeThatWasNotObservedYet() {
    XCTAssertFalse(
      CaptureMetering.hasSettled(lastChange: start, adjustmentObservedAt: nil, now: after(50)))
  }

  func testSettledOnceTheSettleWindowPassedWithoutAdjustment() {
    XCTAssertTrue(
      CaptureMetering.hasSettled(lastChange: start, adjustmentObservedAt: nil, now: after(150)))
  }

  func testSettledWhenAnAdjustmentWasObservedAfterTheChange() {
    XCTAssertTrue(
      CaptureMetering.hasSettled(
        lastChange: start, adjustmentObservedAt: after(20), now: after(40)))
  }

  func testAdjustmentObservedBeforeTheLatestChangeDoesNotCount() {
    XCTAssertFalse(
      CaptureMetering.hasSettled(
        lastChange: after(100), adjustmentObservedAt: after(20), now: after(120)))
  }

  // MARK: Point of interest orientation

  func testLockedOrientationWins() {
    XCTAssertEqual(
      CaptureMetering.pointOfInterestOrientation(
        locked: .landscapeRight, stored: .portrait, provided: .portrait, fallback: .portrait),
      .landscapeRight)
  }

  func testStoredOrientationIsUsedWhenUnlocked() {
    XCTAssertEqual(
      CaptureMetering.pointOfInterestOrientation(
        locked: .unknown, stored: .landscapeLeft, provided: .faceUp, fallback: .portrait),
      .landscapeLeft)
  }

  func testFlatAndUnknownOrientationsFallBack() {
    XCTAssertEqual(
      CaptureMetering.pointOfInterestOrientation(
        locked: .unknown, stored: .faceUp, provided: .portraitUpsideDown, fallback: .portrait),
      .portraitUpsideDown)
    XCTAssertEqual(
      CaptureMetering.pointOfInterestOrientation(
        locked: .unknown, stored: .faceDown, provided: .unknown, fallback: .landscapeRight),
      .landscapeRight)
    XCTAssertEqual(
      CaptureMetering.pointOfInterestOrientation(
        locked: .unknown, stored: .unknown, provided: .faceUp, fallback: .faceUp),
      .portrait)
  }

  func testPointOfInterestMapping() {
    // Binary fractions keep the comparisons exact.
    XCTAssertEqual(
      CaptureMetering.pointOfInterest(x: 0.25, y: 0.125, orientation: .portrait),
      CGPoint(x: 0.125, y: 0.75))
    XCTAssertEqual(
      CaptureMetering.pointOfInterest(x: 0.25, y: 0.125, orientation: .portraitUpsideDown),
      CGPoint(x: 0.875, y: 0.25))
    XCTAssertEqual(
      CaptureMetering.pointOfInterest(x: 0.25, y: 0.125, orientation: .landscapeRight),
      CGPoint(x: 0.75, y: 0.875))
    XCTAssertEqual(
      CaptureMetering.pointOfInterest(x: 0.25, y: 0.125, orientation: .landscapeLeft),
      CGPoint(x: 0.25, y: 0.125))
  }

  func testInterfaceOrientationMapsToTheMatchingDeviceOrientation() {
    XCTAssertEqual(CaptureMetering.deviceOrientation(for: .portrait), .portrait)
    XCTAssertEqual(
      CaptureMetering.deviceOrientation(for: .portraitUpsideDown), .portraitUpsideDown)
    XCTAssertEqual(CaptureMetering.deviceOrientation(for: .landscapeLeft), .landscapeRight)
    XCTAssertEqual(CaptureMetering.deviceOrientation(for: .landscapeRight), .landscapeLeft)
    XCTAssertEqual(CaptureMetering.deviceOrientation(for: .unknown), .portrait)
  }

  // MARK: Stabilization readback

  func testStabilizationSettledOnceTheActiveModeFollowsThePreference() {
    XCTAssertFalse(CaptureMetering.isStabilizationSettled(preferred: .standard, active: .off))
    XCTAssertTrue(CaptureMetering.isStabilizationSettled(preferred: .standard, active: .standard))
    XCTAssertTrue(CaptureMetering.isStabilizationSettled(preferred: .auto, active: .cinematic))
    XCTAssertFalse(CaptureMetering.isStabilizationSettled(preferred: .off, active: .standard))
    XCTAssertTrue(CaptureMetering.isStabilizationSettled(preferred: .off, active: .off))
  }
}
