// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThinPath",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "ThinPath",
            targets: ["ThinPath"]
        )
    ],
    dependencies: [
        // Documentation only: a command plugin invoked via
        // `swift package generate-documentation`. Command plugins are not
        // linked into products, so this never becomes a runtime dependency
        // of the ThinPath library. Version current as of this writing —
        // check https://github.com/swiftlang/swift-docc-plugin/releases
        // before bumping.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "ThinPath",
            dependencies: []
        ),
        .testTarget(
            name: "ThinPathTests",
            dependencies: ["ThinPath"],
            resources: [
                .copy("SampleSVGs")
            ]
        )
    ]
)
