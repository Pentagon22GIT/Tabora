// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tabora",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Tabora", targets: ["Tabora"])],
    targets: [
        .executableTarget(
            name: "Tabora",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "TaboraTests",
            dependencies: ["Tabora"]
        )
    ]
)
