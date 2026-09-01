// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tabora",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Tabora", targets: ["Tabora"])],
    targets: [
        .executableTarget(
            name: "Tabora",
            dependencies: ["TaboraSkyLightBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .target(
            name: "TaboraSkyLightBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Foundation")
            ]
        ),
        .testTarget(
            name: "TaboraTests",
            dependencies: ["Tabora"]
        )
    ]
)
