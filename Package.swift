// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacSanity",
    platforms: [.macOS(.v26)],
    targets: [
        // Private SPI declarations (CGEventCopyIOHIDEvent + IOHIDEvent get/set float).
        // These symbols live in CoreGraphics / IOKit but are absent from the public SDK headers.
        .target(name: "CMacSanitySPI"),

        // Pure, platform-independent logic (the mouse-vs-trackpad classifier),
        // split out so the test target links it without pulling in the GUI app.
        .target(name: "MacSanityCore"),

        // The app itself. SwiftUI is a menu-bar agent; the scroll event-tap hot path is
        // plain Swift over C-callbacks and never touches the UI layer.
        .executableTarget(
            name: "MacSanity",
            dependencies: ["CMacSanitySPI", "MacSanityCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),

        // Pure-logic checks for the classifier, as a standalone runner.
        // (Command Line Tools ship neither XCTest nor Swift Testing, so the
        // conventional test target can't run here — `swift run ClassifierCheck`
        // does the same job and exits non-zero on failure.)
        .executableTarget(
            name: "ClassifierCheck",
            dependencies: ["MacSanityCore"]
        ),
    ]
)
