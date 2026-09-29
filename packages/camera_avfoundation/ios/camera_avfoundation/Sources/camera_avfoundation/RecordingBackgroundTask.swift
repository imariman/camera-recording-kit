// Copyright 2026 Teleprompter Studio. All rights reserved.

import UIKit

/// Keeps the app running while a recording is finalized after the app resigned active.
///
/// On iOS an `AVAssetWriter` that is still writing when the app is suspended fails and leaves an
/// unplayable file, so the camera holds a background task from `willResignActive` until the
/// writer has finished (or nothing is recording). `begin()` and `end()` can be called from any
/// thread; the task identifier is only touched on the main thread.
final class RecordingBackgroundTask {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  func begin() {
    ensureToRunOnMainQueue { [self] in
      guard identifier == .invalid else { return }
      identifier = UIApplication.shared.beginBackgroundTask(
        withName: "camera_avfoundation.finishRecording"
      ) { [self] in
        // The system is about to suspend the app; the task must be ended before that.
        endOnMainThread()
      }
    }
  }

  func end() {
    ensureToRunOnMainQueue { [self] in
      endOnMainThread()
    }
  }

  private func endOnMainThread() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
}
