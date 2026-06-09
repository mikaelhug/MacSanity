import AppKit

/// A minimal, manual update check against the project's GitHub Releases.
///
/// It runs only when the user picks "Check for Updates…": it fetches the latest
/// release, compares versions, and — if a newer one exists — downloads the `.zip`
/// asset, swaps it over the running app, and relaunches (falling back to a Finder
/// reveal if the app's location isn't writable). No background polling.
@MainActor
final class UpdateChecker {
    /// `owner/repo` on GitHub. Update if the repository is renamed/moved.
    private let repo = "mikaelhug/MacSanity"
    private var isChecking = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                handle(try await fetchLatestRelease())
            } catch {
                presentInfo(title: "Couldn’t Check for Updates", text: message(for: error))
            }
        }
    }

    // MARK: Networking

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let url: String
            enum CodingKeys: String, CodingKey { case name; case url = "browser_download_url" }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, assets
        }
    }

    private enum UpdateError: Error { case badURL, http(Int), unzipFailed, noApp }

    private func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("MacSanity", forHTTPHeaderField: "User-Agent")   // GitHub requires this
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw UpdateError.http(code) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: Result handling

    private func handle(_ release: Release) {
        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

        guard Self.isVersion(latest, newerThan: currentVersion) else {
            presentInfo(title: "You’re Up to Date",
                        text: "MacSanity \(currentVersion) is the latest version.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "MacSanity \(latest) is available"
        alert.informativeText = "You have \(currentVersion). MacSanity will download the update and relaunch."
            + notesSuffix(release.body)
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) {
                Task { await downloadAndInstall(zip) }
            } else {
                open(release.htmlURL)   // no asset — fall back to the release page
            }
        case .alertSecondButtonReturn:
            open(release.htmlURL)
        default:
            break
        }
    }

    private func downloadAndInstall(_ asset: Release.Asset) async {
        guard let url = URL(string: asset.url) else { return }
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard ((response as? HTTPURLResponse)?.statusCode ?? -1) == 200 else {
                throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacSanityUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipURL = workDir.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: tempURL, to: zipURL)

            try await unzip(zipURL, into: workDir)

            let newApp = workDir.appendingPathComponent("MacSanity.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError.noApp }
            try installAndRelaunch(newApp: newApp)
        } catch {
            presentInfo(title: "Update Failed", text: message(for: error))
        }
    }

    /// Swap the new app over the running one and relaunch. The swap runs in a
    /// detached shell that first waits for this process to quit (you can't replace
    /// a running bundle in place), then reopens the updated app. Falls back to
    /// revealing the download if we're not a writable .app bundle.
    private func installAndRelaunch(newApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        let parent = currentApp.deletingLastPathComponent()

        guard currentApp.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            presentInfo(title: "Update Downloaded",
                        text: "Drag the new MacSanity into your Applications folder to finish updating.")
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let dest = currentApp.path
        let src = newApp.path
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/ditto "\(src)" "\(dest).new" || exit 1
        /bin/rm -rf "\(dest)"
        /bin/mv "\(dest).new" "\(dest)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
        /usr/bin/open "\(dest)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()       // detached — outlives our termination
        NSApp.terminate(nil)
    }

    /// Unzip with `ditto` off the main thread (its termination handler resumes us),
    /// so the menu-bar app never blocks while expanding the archive.
    private func unzip(_ zip: URL, into dest: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, dest.path]
            process.terminationHandler = { proc in
                proc.terminationStatus == 0 ? cont.resume() : cont.resume(throwing: UpdateError.unzipFailed)
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Helpers

    /// Numeric, component-wise semantic-version comparison ("0.10.0" > "0.9.0").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func notesSuffix(_ body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        let trimmed = body.count <= 500 ? body : String(body.prefix(500)) + "…"
        return "\n\n" + trimmed
    }

    private func message(for error: Error) -> String {
        if case UpdateError.http(let code) = error {
            return code == 404
                ? "No published releases were found for this repository yet."
                : "GitHub returned HTTP \(code)."
        }
        return error.localizedDescription
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func activate() {
        // Bring the alert to the front — an .accessory agent isn't active by default.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        activate()
        alert.runModal()
    }
}
