// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LegulusGeo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LegulusGeo", targets: ["LegulusGeo"])],
    targets: [
        .target(name: "CGeotrans", path: "Sources/CGeotrans", publicHeadersPath: "include"),
        .target(name: "LegulusGeo", dependencies: ["CGeotrans"], resources: [.copy("Resources/admin_labels.json")]),
        .testTarget(name: "LegulusGeoTests", dependencies: ["LegulusGeo"])
    ]
)
