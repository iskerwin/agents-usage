import Darwin
import Foundation

public enum BackendError: LocalizedError {
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "未找到 agents-usage，请先运行 uv tool install ."
        }
    }
}

/// The long-running `agents-usage serve` process. Its stdin closing is what
/// stops it, so it cannot outlive the app.
public final class Backend {
    private var process: Process?
    private var input: FileHandle?
    private let onLine: @Sendable (Data) -> Void
    private let onExit: @Sendable () -> Void

    public init(onLine: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable () -> Void) {
        self.onLine = onLine
        self.onExit = onExit
        // A write to a backend that just died must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public func send(_ command: String) throws {
        if process?.isRunning != true { try start() }
        try input?.write(contentsOf: Data((command + "\n").utf8))
    }

    public func stop() {
        process?.terminate()
    }

    private func start() throws {
        let path = Self.searchPath()
        guard let exe = Self.find("agents-usage", in: path) else { throw BackendError.notInstalled }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["serve"]
        // codex and claude are looked up on PATH by the backend too.
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let onExit = self.onExit
        process.terminationHandler = { _ in onExit() }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting

        let onLine = self.onLine
        // A read error ends the process's output; onExit reports it.
        _ = Task.detached {
            for try await line in stdout.fileHandleForReading.bytes.lines {
                onLine(Data(line.utf8))
            }
        }
    }

    // A GUI app does not inherit the shell's PATH, and on this kind of setup
    // only an interactive login shell has all of it.
    static func searchPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ([loginShellPath()].compactMap { $0 } + fallback + [inherited]).joined(separator: ":")
    }

    static func find(_ name: String, in path: String) -> String? {
        path.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func loginShellPath() -> String? {
        let marker = "__AGENTS_USAGE_PATH__"
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lic", "printf '\(marker)%s\\n' \"$PATH\""]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }

        // Something started by the shell's profile can hold the pipe open, so
        // the read is bounded rather than waiting for end of file.
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        DispatchQueue.global().async {
            result.data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        if shell.isRunning { shell.terminate() }
        guard finished, let text = result.data.flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        return text.split(separator: "\n").last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
    }
}
