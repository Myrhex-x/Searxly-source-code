// swift-tools-version:5.9
//
// Known-answer tests for the security-boundary logic (dApp approval previews + prompt-injection guard).
// mirror/ sources are symlinks to the real files in ../Searxly, so the tests can't drift.
//
import PackageDescription

let package = Package(
    name: "SecurityBoundaryTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned to the current 0.3.0 commit by SHA so it resolves on a clean machine / CI. (A revision
        // pin avoids the version-fingerprint conflict from the tag having been re-pointed upstream.)
        .package(url: "https://github.com/searxly/bulwark",
                 revision: "34c754bb2356687c9bcf7675550203031b17f33d"),
    ],
    targets: [
        .executableTarget(
            name: "SecurityBoundaryTests",
            dependencies: [.product(name: "Bulwark", package: "bulwark")],
            path: "Sources/SecurityBoundaryTests"
        ),
    ]
)
