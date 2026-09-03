// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "DisplayControl",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "DisplayControl", targets: ["DisplayControl"]),
    .executable(name: "ddc-diagnose", targets: ["Diagnose"]),
    .library(name: "DDCKit", targets: ["DDCKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
  ],
  targets: [
    // Declarations for private IOAVService / CoreDisplay symbols.
    .target(name: "CDDCPrivate"),
    // DDC/CI engine + display model (UI-agnostic).
    .target(name: "DDCKit", dependencies: ["CDDCPrivate"], linkerSettings: [
      .linkedFramework("IOKit"),
      .linkedFramework("CoreGraphics"),
      // Private IOAVService/CoreDisplay symbols resolve from the dyld cache.
      .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
    ]),
    .target(name: "DiagnoseSupport"),
    .testTarget(name: "DDCKitTests", dependencies: ["DDCKit", "DiagnoseSupport"]),
    .executableTarget(
      name: "DisplayControl",
      dependencies: ["DDCKit", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
      ]
    ),
    // Default diagnostics are read-only; explicit subcommands can write.
    .executableTarget(name: "Diagnose", dependencies: ["DDCKit", "DiagnoseSupport"]),
  ]
)
