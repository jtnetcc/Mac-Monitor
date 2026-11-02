import Foundation
import AppKit
import Darwin

// MARK: - 进程操作（结束 / 查看 / 定位）
//
// 结束进程走 kill(2)，不需要 entitlement，也不需要辅助进程。
// 非本人进程（root 拥有的 daemon）返回 EPERM，此时改用 osascript 提权：
// 会弹系统密码框，但这是不引入 SMJobBless helper 的唯一办法。

enum KillOutcome {
    case ok
    case needsAdmin
    case gone
    case blocked(String)
    case failed(String)
}

enum ProcessActions {

    /// 结束这些进程会直接注销或让系统不稳定，一律拦下
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow",
        "opendirectoryd", "securityd", "watchdogd", "logind", "powerd"
    ]

    /// 返回不可结束的原因；nil 表示可以结束
    static func blockedReason(_ p: ProcSample) -> String? {
        if p.pid <= 1 { return "PID \(p.pid) 是内核 / 系统根进程，不能结束" }
        if p.pid == getpid() { return "不能结束 Mac Monitor 自身" }
        if protectedNames.contains(p.name.lowercased()) {
            return "\(p.name) 是系统关键进程，结束会导致注销或系统异常"
        }
        return nil
    }

    // MARK: 结束

    static func kill(_ pid: Int32, force: Bool) -> KillOutcome {
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 { return .ok }
        switch errno {
        case EPERM: return .needsAdmin
        case ESRCH: return .gone
        default:    return .failed(String(cString: strerror(errno)))
        }
    }

    /// 提权结束：osascript 会弹系统授权框，脚本在后台线程等用户输入
    static func killWithAdmin(_ pid: Int32, force: Bool, completion: @escaping (Bool) -> Void) {
        runAdminShell("/bin/kill -\(force ? "KILL" : "TERM") \(pid)", completion: completion)
    }

    static func runAdminShell(_ command: String, completion: @escaping (Bool) -> Void) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        runAppleScript("do shell script \"\(escaped)\" with administrator privileges",
                       completion: completion)
    }

    /// 不需要 root 的命令
    static func runShell(_ command: String, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            }
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    private static func runAppleScript(_ source: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            // 必须重定向，否则管道写满会卡死
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil {
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: 查询

    static func pathOf(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }

    static func userName(_ uid: UInt32) -> String {
        if uid == 0 { return "root" }
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return "uid \(uid)"
    }

    static func statusText(_ s: UInt32) -> String {
        switch s {
        case 1: return "空闲"
        case 2: return "运行中"
        case 3: return "睡眠"
        case 4: return "已停止"
        case 5: return "僵尸"
        default: return "—"
        }
    }

    /// 详情用的一次性完整采样（只在打开详情时调用，不进采样循环）
    static func detail(for p: ProcSample) -> ProcessDetail {
        var d = ProcessDetail()
        d.pid = p.pid
        d.name = p.name
        d.path = p.path
        d.user = p.user
        d.uid = p.uid
        d.threads = p.threads
        d.cpu = p.cpu
        d.mem = p.mem
        d.start = p.start
        d.isSystem = p.isSystem

        var bsd = proc_bsdinfo()
        let bsz = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(p.pid, PROC_PIDTBSDINFO, 0, &bsd, bsz) == bsz {
            d.ppid = Int32(bsd.pbi_ppid)
            d.uid = bsd.pbi_uid
            d.user = userName(bsd.pbi_uid)
            d.status = statusText(bsd.pbi_status)
            if bsd.pbi_start_tvsec > 0 {
                d.start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
            }
        }

        var info = proc_taskinfo()
        let tsz = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(p.pid, PROC_PIDTASKINFO, 0, &info, tsz) == tsz {
            d.threads = Int(info.pti_threadnum)
            d.mem = info.pti_resident_size
        }

        if d.path.isEmpty, let path = pathOf(p.pid) { d.path = path }
        if d.user.isEmpty { d.user = userName(d.uid) }
        return d
    }

    // MARK: 杂项

    static func reveal(_ p: ProcSample) {
        let path = p.path.isEmpty ? (pathOf(p.pid) ?? "") : p.path
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    static func restartFinder() {
        runShell("/usr/bin/killall Finder")
    }

    static func flushDNS(_ done: @escaping (Bool) -> Void) {
        runAdminShell("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", completion: done)
    }

    static func purgeMemory(_ done: @escaping (Bool) -> Void) {
        runAdminShell("/usr/bin/purge", completion: done)
    }

    // MARK: 确认框

    @discardableResult
    static func confirm(title: String, message: String, okTitle: String,
                        destructive: Bool = false) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .critical : .warning
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }
}
