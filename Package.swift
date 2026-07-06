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
  targets: [
    // Declarations for private IOAVService / CoreDisplay symbols.
    .target(name: "CDDCPrivate"),
    // DDC/CI engine + display model (UI-agnostic).
    .target(name: "DDCKit", dependencies: ["CDDCPrivate"]),
    // Menu bar app.
    .executableTarget(
      name: "DisplayControl",
      dependencies: ["DDCKit"],
      linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("CoreGraphics"),
        // IOAVService*/CoreDisplay_* live in the dyld shared cache but aren't in
        // the SDK stubs, so resolve them at runtime.
        .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
      ]
    ),
    // Headless DDC diagnostics (read-only): list displays + detected features.
    .executableTarget(
      name: "Diagnose",
      dependencies: ["DDCKit"],
      linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("CoreGraphics"),
        .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
      ]
    ),
  ]
)
