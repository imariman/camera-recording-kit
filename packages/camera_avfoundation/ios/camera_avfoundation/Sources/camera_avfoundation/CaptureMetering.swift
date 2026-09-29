// Copyright 2026 Camera Recording Kit contributors
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file at the root of this repository.

import AVFoundation
import UIKit

/// Pure focus/exposure, orientation and stabilization decisions used by `DefaultCamera`.
/// Kept free of device access so they can be unit tested.
enum CaptureMetering {
  /// How long an idle reading must follow a metering change before it is trusted, unless the
  /// device was already seen adjusting after that change.
  static let settleWindow = DispatchTimeInterval.milliseconds(150)

  /// Whether an idle focus/exposure reading means convergence: no metering change is pending,
  /// the device was seen adjusting after the latest change, or the settle window has passed
  /// without AVFoundation starting an adjustment.
  static func hasSettled(
    lastChange: DispatchTime?,
    adjustmentObservedAt: DispatchTime?,
    now: DispatchTime,
    window: DispatchTimeInterval = settleWindow
  ) -> Bool {
    guard let lastChange else { return true }
    if let observed = adjustmentObservedAt, observed >= lastChange { return true }
    return now >= lastChange + window
  }

  /// The orientation used to map a preview point to the sensor's point of interest.
  ///
  /// A locked capture orientation wins, like in the Dart preview. Otherwise the orientation last
  /// delivered to the camera is used, then the live device orientation. Flat (`.faceUp`,
  /// `.faceDown`) and `.unknown` orientations say nothing about how the preview is shown, so
  /// they fall back to `fallback` (the last known interface orientation).
  static func pointOfInterestOrientation(
    locked: UIDeviceOrientation,
    stored: UIDeviceOrientation,
    provided: UIDeviceOrientation,
    fallback: UIDeviceOrientation
  ) -> UIDeviceOrientation {
    for candidate in [locked, stored, provided] where candidate.isValidInterfaceOrientation {
      return candidate
    }
    return fallback.isValidInterfaceOrientation ? fallback : .portrait
  }

  /// Maps a normalized preview point to the sensor coordinate space (landscape, home button on
  /// the right) for the given interface-valid orientation.
  static func pointOfInterest(
    x: Double, y: Double, orientation: UIDeviceOrientation
  ) -> CGPoint {
    switch orientation {
    case .portrait:  // 90 ccw
      return CGPoint(x: y, y: 1 - x)
    case .portraitUpsideDown:  // 90 cw
      return CGPoint(x: 1 - y, y: x)
    case .landscapeRight:  // 180
      return CGPoint(x: 1 - x, y: 1 - y)
    default:
      // .landscapeLeft matches the sensor orientation: no rotation required.
      return CGPoint(x: x, y: y)
    }
  }

  /// The device orientation matching an interface orientation. The landscape cases are swapped:
  /// rotating the device left turns the interface right.
  static func deviceOrientation(for interfaceOrientation: UIInterfaceOrientation)
    -> UIDeviceOrientation
  {
    switch interfaceOrientation {
    case .portrait: return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft: return .landscapeRight
    case .landscapeRight: return .landscapeLeft
    default: return .portrait
    }
  }

  /// Whether a connection's active stabilization mode reflects the preferred one. AVFoundation
  /// updates `activeVideoStabilizationMode` asynchronously after the preference changes.
  static func isStabilizationSettled(
    preferred: AVCaptureVideoStabilizationMode,
    active: AVCaptureVideoStabilizationMode
  ) -> Bool {
    return preferred == .off ? active == .off : active != .off
  }
}
