import AppKit
import Darwin

/// Brings forward the terminal an agent runs in, down to the pane when the
/// terminal can be told which one. Terminals that keep their sessions in a
/// server of their own have no app among the process's ancestors, so that
/// server stands in for the app.
public enum TerminalOpener {
    private static let rexBundle = "com.superlogical.rex"
    private static let serverApps = ["RexServer": rexBundle]

    @MainActor
    public static func open(_ task: Snapshot.AgentTask) {
        if let pane = RexPane(environment: processEnvironment(of: task.pid)),
           let rex = NSRunningApplication.runningApplications(withBundleIdentifier: rexBundle).first {
            let appPID = rex.processIdentifier
            let url = rex.bundleURL
            // rex is a round trip to its server, too slow for the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                pane.reveal(inAppWithPID: appPID)
                activate(url)
            }
        } else if let app = hostApp(of: task.pid) {
            activate(app.bundleURL)
        } else if let cwd = task.cwd {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", cwd]
            try? process.run()
        }
    }

    /// Through the workspace, as `NSRunningApplication.activate` is ignored when
    /// asked from a panel that never made this app active.
    private static func activate(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    private static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        while current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            if let bundle = serverApps[processName(current)],
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                return app
            }
            guard let parent = parentPID(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&request, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func processName(_ pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&request, 4, &info, &size, nil, 0) == 0 else { return "" }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func processEnvironment(of pid: pid_t) -> [String: String] {
        var request = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&request, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&request, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        return environment(fromProcessArguments: Data(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` lays out argc, the executable's path, then argv and the
    /// environment, all separated by runs of NULs.
    static func environment(fromProcessArguments data: Data) -> [String: String] {
        guard data.count > 4 else { return [:] }
        let argc = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let strings = data.dropFirst(4).split(separator: 0).dropFirst(1 + max(Int(argc), 0))
        var result: [String: String] = [:]
        for bytes in strings {
            let pair = String(decoding: bytes, as: UTF8.self).split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }
}

/// The pane a process runs in, from the variables Rex sets in every terminal.
struct RexPane {
    private static let cli = NSHomeDirectory() + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

    let server: String?
    let session: String
    let block: String

    init?(environment: [String: String]) {
        guard let session = environment["REX_SESSION"], let block = environment["REX_BLOCK"] else { return nil }
        self.server = environment["REX_SERVER"]
        self.session = session
        self.block = block
    }

    /// Focus lives on the server and picks the tab along with the pane. Showing
    /// another session is up to the app, which refuses unless its Remote Control
    /// setting is on, and then stays on the session it was showing.
    func reveal(inAppWithPID appPID: pid_t) {
        _ = run(["api", "call", "-s", session, "session.focus_block", "{\"block_id\":\"\(block)\"}"])
        guard let clients = json(["client", "ls", "--json"])?["clients"] as? [[String: Any]],
              let client = clients.first(where: { ($0["principal"] as? [String: Any])?["pid"] as? Int == Int(appPID) })?["client_id"] as? String
        else { return }
        _ = run(["-C", client, "do", "session.select", "session_id=\(session)"])
    }

    private func json(_ arguments: [String]) -> [String: Any]? {
        run(arguments).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.cli)
        process.arguments = ["--timeout", "3s"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["REX_SERVER"] = server
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
