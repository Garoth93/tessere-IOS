// swift-tools-version: 5.9
// Logic package for the Tessere app. Pure Swift (Foundation only):
// it must build and test on Linux with `swift test`.
import PackageDescription

let package = Package(
    name: "TessereCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "TessereCore", targets: ["TessereCore"])
    ],
    targets: [
        .target(
            name: "TessereCore",
            path: "Sources/TessereCore"
        ),
        .testTarget(
            name: "TessereCoreTests",
            dependencies: ["TessereCore"],
            path: "Tests/TessereCoreTests"
        )
    ]
)
