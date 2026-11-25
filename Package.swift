// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pica",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pica",
            path: "Sources/Pica"
        ),
        .testTarget(
            name: "PicaTests",
            dependencies: ["Pica"],
            path: "Tests/PicaTests"
        ),
    ]
)
