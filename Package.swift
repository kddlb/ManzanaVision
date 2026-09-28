// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-2.0-only
import PackageDescription

let package = Package(
    name: "ManzanaVision",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ManzanaCore", targets: ["ManzanaCore"]),
    ],
    targets: [
        // libusb 1.0.30, macOS backend only, built from source so the app
        // doesn't depend on Homebrew (LGPL-2.1-or-later, see vendor/libusb).
        .target(
            name: "CLibUSB",
            path: "vendor/libusb",
            exclude: ["COPYING", "AUTHORS", "README.vendor"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/os"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        // The tuner core: bridge, vendored Linux frontends, board glue, PSI.
        // The CLI-only files stay with the Makefile build.
        .target(
            name: "ManzanaCore",
            dependencies: ["CLibUSB"],
            path: "src",
            exclude: ["cli", "frontends/PATCHES.md"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("compat"),
                .headerSearchPath("frontends"),
                .headerSearchPath("bridge"),
                .headerSearchPath("board"),
                .headerSearchPath("ts"),
                .headerSearchPath("core"),
            ]
        ),
        .executableTarget(
            name: "mzvtool",
            dependencies: ["ManzanaCore", "CLibUSB"]
        ),
        .testTarget(
            name: "ManzanaCoreTests",
            dependencies: ["ManzanaCore"]
        ),
    ],
    cLanguageStandard: .gnu11
)
