// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Redakciya",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Personal data detector shared with Zamazka (product ZamazkaKit). Pinned to a commit: Zamazka is
        // a published app, its main moves on its own schedule.
        .package(url: "https://github.com/vldvr/zamazka", revision: "738d6dac5a5c8c7f0bcf30100b8d9c3ed65c5de2"),
    ],
    targets: [
        // Modules by spec/: Editing (link tails), later Desk, Archive, Reprint, Issue.
        .executableTarget(name: "Redakciya", dependencies: ["RedakciyaKit"]),
        .target(
            name: "RedakciyaKit",
            dependencies: [.product(name: "ZamazkaKit", package: "zamazka")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        // Shared corpus from spec/: `swift run redakciya-checks`. Windows runs the same cases with `cargo test`.
        .executableTarget(
            name: "redakciya-checks",
            dependencies: ["RedakciyaKit", .product(name: "ZamazkaKit", package: "zamazka")],
            path: "Checks"
        ),
    ]
)
