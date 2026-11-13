import Foundation

/// Runs a tool without a shell (arguments are passed as an array, so paths are
/// never interpreted), with a timeout. Blocking — call from `DiskIO.run`.
enum Command {
    struct Result: Sendable {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Resolve a tool name to an executable path: absolute paths as-is, else the
    /// usual Homebrew / system locations (GUI apps don't inherit the shell PATH).
    static func locate(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        let home = NSHomeDirectory()
        let dirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin",
                    "/usr/local/go/bin", home + "/go/bin", home + "/.cargo/bin", home + "/.local/bin"]
        return dirs.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 30,
                    workingDirectory: String? = nil) -> Result {
        guard let executable = locate(tool) else { return Result(status: 127, output: "\(tool): not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: 126, output: error.localizedDescription) }

        // Read concurrently so a chatty tool can't block on a full pipe.
        let collected = OutputBox()
        let reader = Thread {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        return Result(status: process.terminationStatus,
                      output: String(decoding: collected.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }
}
