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
