// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SVGRenderer",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "SVGRenderer",
            targets: ["SVGRenderer"]
        )
    ],
    targets: [
        .target(
            name: "SVGRenderer",
            dependencies: []
        ),
        .testTarget(
            name: "SVGRendererTests",
            dependencies: ["SVGRenderer"],
            resources: [
                .copy("SampleSVGs")
            ]
        )
    ]
)
