import AppKit
import Darwin

/// Brings forward the terminal an agent runs in. Terminals that keep their
/// sessions in a server of their own have no app among the process's ancestors,
/// so that server stands in for the app.
public enum TerminalOpener {
    private static let serverApps = ["RexServer": "com.superlogical.rex"]

    @MainActor
    public static func open(_ task: Snapshot.AgentTask) {
        if let app = hostApp(of: task.pid) {
            app.activate()
        } else if let cwd = task.cwd {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", cwd]
            try? process.run()
        }
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
}
