// swift-tools-version: 5.9

// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import PackageDescription

let package = Package(
  name: "camera_avfoundation_frame_frame_frame_frame",
  platforms: [
    .iOS("12.0")
  ],
  products: [
    .library(
      name: "camera-avfoundation", targets: ["camera_avfoundation_frame_frame_frame_frame", "camera_avfoundation_frame_frame_frame_frame_objc"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "camera_avfoundation_frame_frame_frame_frame",
      dependencies: ["camera_avfoundation_frame_frame_frame_frame_objc"],
      path: "Sources/camera_avfoundation_frame_frame_frame_frame",
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "camera_avfoundation_frame_frame_frame_frame_objc",
      dependencies: [],
      path: "Sources/camera_avfoundation_frame_frame_frame_frame_objc",
      resources: [
        .process("Resources")
      ],
      cSettings: [
        .headerSearchPath("include/camera_avfoundation_frame_frame_frame_frame")
      ]
    ),
  ]
)
