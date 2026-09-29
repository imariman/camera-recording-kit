// swift-tools-version: 5.9

// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import PackageDescription

let package = Package(
  name: "camera_avfoundation",
  platforms: [
    .iOS("13.0")
  ],
  products: [
    .library(
      name: "camera-avfoundation", targets: ["camera_avfoundation"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "camera_avfoundation",
      path: "Sources/camera_avfoundation",
      resources: [
        .process("Resources")
      ]
    ),
    // Device-free unit tests of pure logic (format selection, capability building, metering
    // and orientation decisions). Run with `python3 tool/test_ios_camera_native.py`.
    .testTarget(
      name: "camera_avfoundationTests",
      dependencies: ["camera_avfoundation"],
      path: "Tests/camera_avfoundationTests"
    ),
  ]
)
