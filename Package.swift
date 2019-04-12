// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "URITemplate",
  products: [
      .library(
          name: "URITemplate",
          targets: ["URITemplate"]),
  ],
  dependencies: [
      // .package(url: "https://github.com/kylef/Spectre.git", .upToNextMajor(from: "0.7.0")),
      // .package(url: "https://github.com/kylef/PathKit.git", .upToNextMajor(from: "0.7.0")),
  ],
  targets: [
      .target(
          name: "URITemplate",
          dependencies: []),
      // .testTarget(
      //     name: "URITemplateTests",
      //     dependencies: ["URITemplate", "PathKit", "Spectre"])
  ]
)
