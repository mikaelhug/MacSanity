/// A known junk location, described declaratively. The engine expands `paths`
/// (with `~` and `*` wildcards), sizes what exists, and turns it into findings.
public struct CatalogEntry: Sendable, Identifiable {
    public enum Action: Sendable, Equatable {
        /// Move each matched path to the Trash.
        case trash
        /// Run a tool's own cleanup command (shown verbatim before running).
        /// Falls back to `.trash` of the matched paths if the tool isn't installed,
        /// unless `fallbackToTrash` is false.
        case command([String], fallbackToTrash: Bool)
        /// Shown with its size, never removable here (managed by its own app).
        case reportOnly(hint: String)
    }

    public let id: String
    public let title: String
    /// What it is, in one sentence.
    public let explanation: String
    /// What happens after removal.
    public let afterRemoval: String
    public let category: CleanerCategory
    public let paths: [String]
    public let safety: Safety
    public let action: Action
    /// Among matched siblings, offer only superseded versions (keep the newest).
    public let onlyOldVersions: Bool
    /// Bundle IDs that must not be running while this is removed.
    public let quitFirst: [String]
    /// Executable names whose running processes block removal ("cargo", "go").
    public let blockingProcesses: [String]

    public init(id: String, title: String, explanation: String, afterRemoval: String,
                category: CleanerCategory = .developer, paths: [String], safety: Safety = .safe,
                action: Action = .trash, onlyOldVersions: Bool = false,
                quitFirst: [String] = [], blockingProcesses: [String] = []) {
        self.id = id; self.title = title; self.explanation = explanation
        self.afterRemoval = afterRemoval; self.category = category; self.paths = paths
        self.safety = safety; self.action = action; self.onlyOldVersions = onlyOldVersions
        self.quitFirst = quitFirst; self.blockingProcesses = blockingProcesses
    }
}

public enum Catalog {
    static let rebuilt = "Rebuilt automatically the next time it's needed."
    static let redownloaded = "Downloaded again the next time a project needs it."

    /// Developer tools, package managers and SDKs.
    public static let developer: [CatalogEntry] = [
        // Xcode
        .init(id: "xcode.deriveddata", title: "Xcode DerivedData",
              explanation: "Xcode's build products and indexes for every project you've opened.",
              afterRemoval: "The next build of each project starts from scratch (slower once).",
              paths: ["~/Library/Developer/Xcode/DerivedData/*"], quitFirst: ["com.apple.dt.Xcode"]),
        .init(id: "xcode.archives", title: "Xcode Archives",
              explanation: "App archives created by Product → Archive.",
              afterRemoval: "You can no longer re-export or symbolicate those builds.",
              paths: ["~/Library/Developer/Xcode/Archives/*"], safety: .review),
        .init(id: "xcode.devicesupport", title: "Old device support files",
              explanation: "Debug symbols Xcode copied from devices running older OS versions.",
              afterRemoval: "Copied again if you connect a device with that OS version.",
              paths: ["~/Library/Developer/Xcode/iOS DeviceSupport/*", "~/Library/Developer/Xcode/watchOS DeviceSupport/*",
                      "~/Library/Developer/Xcode/tvOS DeviceSupport/*", "~/Library/Developer/Xcode/visionOS DeviceSupport/*"],
              onlyOldVersions: true, quitFirst: ["com.apple.dt.Xcode"]),
        .init(id: "xcode.previews", title: "SwiftUI preview data",
              explanation: "Simulator data used to render Xcode previews.", afterRemoval: rebuilt,
              paths: ["~/Library/Developer/Xcode/UserData/Previews"], quitFirst: ["com.apple.dt.Xcode"]),
        .init(id: "simulator.caches", title: "Simulator caches",
              explanation: "Caches shared by all iOS simulators.", afterRemoval: rebuilt,
              paths: ["~/Library/Developer/CoreSimulator/Caches"], quitFirst: ["com.apple.iphonesimulator"]),
        .init(id: "simulator.unavailable", title: "Unavailable simulators",
              explanation: "Simulators for OS runtimes that are no longer installed.",
              afterRemoval: "Nothing — they can't be launched anyway.",
              paths: [], action: .command(["xcrun", "simctl", "delete", "unavailable"], fallbackToTrash: false)),
        // Swift / Apple package managers
        .init(id: "swiftpm", title: "Swift Package Manager cache",
              explanation: "Downloaded Swift package sources and manifests.", afterRemoval: redownloaded,
              paths: ["~/Library/Caches/org.swift.swiftpm", "~/Library/org.swift.swiftpm"], blockingProcesses: ["swift-build", "swift-package"]),
        .init(id: "cocoapods", title: "CocoaPods cache", explanation: "Downloaded pod sources.",
              afterRemoval: redownloaded, paths: ["~/Library/Caches/CocoaPods"]),
        .init(id: "carthage", title: "Carthage cache", explanation: "Downloaded Carthage dependencies.",
              afterRemoval: redownloaded, paths: ["~/Library/Caches/org.carthage.CarthageKit"]),
        // Go
        .init(id: "go.build", title: "Go build cache",
              explanation: "Compiled Go packages from every build and test run.", afterRemoval: rebuilt,
              paths: ["~/Library/Caches/go-build"], blockingProcesses: ["go"]),
        .init(id: "go.modcache", title: "Go module cache",
              explanation: "Source of every Go module version you've downloaded.", afterRemoval: redownloaded,
              paths: ["~/go/pkg/mod"], safety: .review,
              action: .command(["go", "clean", "-modcache"], fallbackToTrash: true), blockingProcesses: ["go"]),
        // JavaScript
        .init(id: "npm", title: "npm cache", explanation: "Every npm package tarball you've installed.",
              afterRemoval: redownloaded, paths: ["~/.npm/_cacache", "~/.npm/_npx"], blockingProcesses: ["npm", "npx"]),
        .init(id: "yarn", title: "Yarn cache", explanation: "Downloaded Yarn packages.",
              afterRemoval: redownloaded, paths: ["~/Library/Caches/Yarn", "~/.yarn/berry/cache"], blockingProcesses: ["yarn"]),
        .init(id: "pnpm", title: "pnpm store", explanation: "pnpm's shared package store.",
              afterRemoval: "Projects re-link packages on the next install.",
              paths: ["~/Library/pnpm/store", "~/.pnpm-store", "~/.local/share/pnpm/store"], safety: .review, blockingProcesses: ["pnpm"]),
        .init(id: "bun", title: "Bun cache", explanation: "Downloaded Bun packages.",
              afterRemoval: redownloaded, paths: ["~/.bun/install/cache"], blockingProcesses: ["bun"]),
        .init(id: "node-gyp", title: "node-gyp headers", explanation: "Node.js headers for building native modules.",
              afterRemoval: redownloaded, paths: ["~/Library/Caches/node-gyp"]),
        .init(id: "typescript", title: "TypeScript cache", explanation: "Type definitions fetched by editors.",
              afterRemoval: rebuilt, paths: ["~/Library/Caches/typescript"]),
        .init(id: "playwright", title: "Old Playwright browsers",
              explanation: "Browser builds downloaded by older Playwright versions.",
              afterRemoval: "Downloaded again only if an old project still pins that version.",
              paths: ["~/Library/Caches/ms-playwright/*"], onlyOldVersions: true),
        // Python
        .init(id: "pip", title: "pip cache", explanation: "Downloaded Python wheels.", afterRemoval: redownloaded,
              paths: ["~/Library/Caches/pip"], blockingProcesses: ["pip", "pip3"]),
        .init(id: "uv", title: "uv cache", explanation: "Downloaded and built Python packages.", afterRemoval: redownloaded,
              paths: ["~/.cache/uv", "~/Library/Caches/uv"], blockingProcesses: ["uv"]),
        .init(id: "poetry", title: "Poetry cache", explanation: "Downloaded packages and virtualenv seeds.",
              afterRemoval: redownloaded, paths: ["~/Library/Caches/pypoetry"]),
        .init(id: "conda", title: "Conda package cache", explanation: "Downloaded conda packages.",
              afterRemoval: redownloaded, paths: ["~/miniconda3/pkgs", "~/anaconda3/pkgs", "~/miniforge3/pkgs"], safety: .review),
        .init(id: "huggingface", title: "Hugging Face models", explanation: "Downloaded AI models and datasets.",
              afterRemoval: "Downloaded again (can be many GB) the next time they're used.",
              paths: ["~/.cache/huggingface"], safety: .review),
        .init(id: "pre-commit", title: "pre-commit environments", explanation: "Hook environments built by pre-commit.",
              afterRemoval: rebuilt, paths: ["~/.cache/pre-commit"]),
        // Rust
        .init(id: "cargo.registry", title: "Cargo registry cache", explanation: "Downloaded crate archives and sources.",
              afterRemoval: redownloaded, paths: ["~/.cargo/registry/cache", "~/.cargo/registry/src", "~/.cargo/git/checkouts"],
              blockingProcesses: ["cargo", "rustc"]),
        .init(id: "rustup.toolchains", title: "Rust toolchains", explanation: "Installed Rust compiler toolchains.",
              afterRemoval: "Remove only ones you don't use; reinstall with rustup.",
              paths: ["~/.rustup/toolchains/*"], safety: .review, blockingProcesses: ["cargo", "rustc"]),
        // JVM
        .init(id: "gradle.caches", title: "Gradle caches", explanation: "Downloaded dependencies and build caches.",
              afterRemoval: redownloaded, paths: ["~/.gradle/caches"], blockingProcesses: ["java"]),
        .init(id: "gradle.wrappers", title: "Old Gradle versions", explanation: "Gradle distributions fetched by older projects.",
              afterRemoval: "Downloaded again only by a project still using that version.",
              paths: ["~/.gradle/wrapper/dists/*"], onlyOldVersions: true, blockingProcesses: ["java"]),
        .init(id: "maven", title: "Maven repository", explanation: "Downloaded Java libraries.",
              afterRemoval: redownloaded, paths: ["~/.m2/repository"], safety: .review, blockingProcesses: ["java", "mvn"]),
        // Others
        .init(id: "homebrew", title: "Homebrew downloads", explanation: "Old bottles and source downloads kept by Homebrew.",
              afterRemoval: "Nothing — installed packages are untouched.",
              paths: ["~/Library/Caches/Homebrew"], action: .command(["brew", "cleanup", "--prune=all"], fallbackToTrash: true),
              blockingProcesses: ["brew"]),
        .init(id: "jetbrains", title: "Old JetBrains IDE caches", explanation: "Caches and logs of IDE versions you've upgraded from.",
              afterRemoval: "Nothing — current versions keep their own.",
              paths: ["~/Library/Caches/JetBrains/*", "~/Library/Logs/JetBrains/*"], onlyOldVersions: true),
        .init(id: "vscode.extensions", title: "Old VS Code extension versions",
              explanation: "Previous versions VS Code keeps after updating extensions.",
              afterRemoval: "Nothing — the current version of each extension stays.",
              paths: ["~/.vscode/extensions/*", "~/.cursor/extensions/*"], onlyOldVersions: true),
        .init(id: "docker", title: "Docker disk image", explanation: "Docker's VM disk with all images, containers and volumes.",
              afterRemoval: "", paths: ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"],
              safety: .review, action: .reportOnly(hint: "Run `docker system prune -a` to shrink it.")),
        .init(id: "ollama", title: "Ollama models", explanation: "Local AI models downloaded with Ollama.",
              afterRemoval: "", paths: ["~/.ollama/models"], safety: .review,
              action: .reportOnly(hint: "Run `ollama rm <model>` for models you no longer use.")),
    ]

    /// Electron/Chromium cache subfolders found inside an app's Application Support folder.
    public static let chromiumCacheFolders = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "ShaderCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache",
        "Crashpad/completed", "CachedData", "CachedExtensionVSIXs", "component_crx_cache",
    ]

    /// Updater download leftovers (Squirrel/ShipIt, Sparkle).
    public static func isUpdaterLeftover(_ name: String) -> Bool {
        name.hasSuffix(".ShipIt") || name == "org.sparkle-project.Sparkle" || name == "SquirrelTemp"
    }

    /// Project markers and the build-artifact folders each one produces. Only
    /// these exact names next to the marker are offered — never `dist` or a bare
    /// `build` without a build system that owns it.
    public struct ProjectKind: Sendable {
        public let name: String
        public let markers: [String]
        public let artifacts: [String]
    }

    public static let projectKinds: [ProjectKind] = [
        .init(name: "Rust", markers: ["Cargo.toml"], artifacts: ["target"]),
        .init(name: "Swift", markers: ["Package.swift"], artifacts: [".build", ".swiftpm/xcode/xcuserdata"]),
        .init(name: "Node.js", markers: ["package.json"],
              artifacts: ["node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular/cache", ".vite"]),
        .init(name: "Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
              artifacts: ["build", ".gradle"]),
        .init(name: "Maven", markers: ["pom.xml"], artifacts: ["target"]),
        .init(name: "Python", markers: ["pyproject.toml", "setup.py", "requirements.txt"],
              artifacts: [".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox"]),
        .init(name: "CMake", markers: ["CMakeLists.txt"], artifacts: ["build", "cmake-build-debug", "cmake-build-release"]),
        .init(name: "Zig", markers: ["build.zig"], artifacts: ["zig-cache", ".zig-cache", "zig-out"]),
        .init(name: "Dart", markers: ["pubspec.yaml"], artifacts: [".dart_tool", "build"]),
    ]

    /// Folders never descended into while looking for projects.
    public static let projectWalkSkips: Set<String> = [
        "Library", ".Trash", "node_modules", ".git", ".build", "target", ".venv", "venv",
        "Applications", "Pictures", "Music", "Movies", ".npm", ".cargo", ".rustup", ".gradle", ".m2",
        "go", ".cache", "DerivedData", "Pods",
    ]
}
