import Foundation

// MARK: - 数据模型

struct CPUSample {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
    var pAvg: Double = 0
    var eAvg: Double = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
}

struct MemorySample {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var compressed: UInt64 = 0
    var wired: UInt64 = 0
    var pressure: Int = 1          // 1 正常 / 2 警告 / 4 危险
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var ratio: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
    var pressureText: String {
        switch pressure {
        case 1: return "正常"
        case 2: return "警告"
        case 4: return "危险"
        default: return "—"
        }
    }
}

struct NetworkSample {
    var down: Double = 0          // bytes/s
    var up: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var interfaceName: String = ""
}

struct DiskSample {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var free: UInt64 = 0
    var fsType: String = "—"
    var blockSize: UInt64 = 0
    var readBps: Double = 0
    var writeBps: Double = 0

    var ratio: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

struct BatterySample {
    var percent: Int = 0
    var charging: Bool = false
    var pluggedIn: Bool = false
    var minutesRemaining: Int = -1
    var health: Double = 0
    var cycles: Int = 0
    var designCapacity: Double = 0
    var fullCapacity: Double = 0
    var available: Bool = false
}

struct ProcSample: Identifiable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpu: Double
    var mem: UInt64
    var threads: Int = 0
    var uid: UInt32 = 0
    var user: String = ""
    var path: String = ""
    var start: Date?
    var isSystem: Bool = false
    /// 系统进程（root 拥有的 daemon）在非特权进程里读不到 taskinfo，
    /// CPU / 内存只能显示为「—」，但不影响结束它们（会走提权）
    var hasMetrics: Bool = true

    /// CPU 相近时按内存降序——系统空闲时一堆 0.0% 并列，
    /// 没有这个次级排序列表每次刷新都会乱跳。
    /// 用「0.05% 一档」的量化分桶而不是差值容差：容差比较不满足传递性，
    /// 会让 0.3% 排到 0.4% 前面。
    static func byCPU(_ a: ProcSample, _ b: ProcSample) -> Bool {
        if a.hasMetrics != b.hasMetrics { return a.hasMetrics }
        let ba = Int(a.cpu * 20), bb = Int(b.cpu * 20)
        if ba != bb { return ba > bb }
        return a.mem > b.mem
    }
}

/// 进程详情（打开详情面板时一次性抓取，不进采样循环）
struct ProcessDetail {
    var pid: Int32 = 0
    var ppid: Int32 = 0
    var name: String = ""
    var path: String = ""
    var user: String = ""
    var uid: UInt32 = 0
    var threads: Int = 0
    var cpu: Double = 0
    var mem: UInt64 = 0
    var start: Date?
    var status: String = "—"
    var isSystem: Bool = false

    var uptimeText: String {
        guard let start else { return "—" }
        let t = Int(Date().timeIntervalSince(start))
        if t < 0 { return "—" }
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分 \(t % 60) 秒" }
        return "\(t) 秒"
    }
}

/// 进程列表排序方式
enum ProcSort: String, CaseIterable, Identifiable {
    case cpu = "CPU", mem = "内存", name = "名称", pid = "PID"
    var id: String { rawValue }
}

/// 菜单栏显示的指标
enum StatusMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "内存", network = "网络", temp = "温度"
    var id: String { rawValue }
}

/// 一次性操作反馈（结束进程的结果等）
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let ok: Bool
}

struct SensorSample {
    var cpuTemp: Double = 0
    var gpuTemp: Double = 0
    var socTemp: Double = 0
    var ssdTemp: Double = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// -1 表示本机不可读（Apple Silicon 上 AppleSMC 风扇键值实测返回空）
    var fanRPM: Double = -1

    var thermalText: String {
        switch thermalState {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "严重"
        case .critical: return "危险"
        @unknown default: return "—"
        }
    }

    var thermalLevel: Int {
        switch thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

struct GPUSample {
    var utilization: Double = 0
    var memUsed: UInt64 = 0
    var available: Bool = false
}

// MARK: - 机器配置

struct SystemInfo {
    var modelName: String = "—"          // MacBook Pro
    var modelIdentifier: String = "—"    // MacBookPro17,1
    var chip: String = "—"               // Apple M1
    var memoryType: String = ""          // LPDDR4X
    var totalCores: Int = 0
    var pCores: Int = 0
    var eCores: Int = 0
    var memoryBytes: UInt64 = 0
    var serial: String = "—"
    var osVersion: String = "—"
    var osBuild: String = "—"
    var hostname: String = "—"
    var localIP: String = "—"
    var bootTime: Date = Date()
    var displayPoints: String = "—"
    var displayPixels: String = "—"
    var displayScale: Int = 2
    var arch: String = "—"

    var uptime: TimeInterval {
        Date().timeIntervalSince(bootTime)
    }

    var uptimeText: String {
        let t = Int(uptime)
        let d = t / 86400
        let h = (t % 86400) / 3600
        let m = (t % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分"
    }
}

// MARK: - 时间范围

enum TimeRange: String, CaseIterable {
    case m1 = "60秒", m5 = "5分钟", h1 = "1小时", h24 = "24小时"
}

// MARK: - 多分辨率历史缓冲
//
// 单一环形缓冲无法同时支撑「看最近 60 秒的抖动」和「看 24 小时趋势」——
// 2 秒粒度存 24 小时要 4 万个点。所以每个指标维护 4 个不同采样率的下采样序列。

final class Series {
    let interval: TimeInterval
    let capacity: Int
    private(set) var values: [Double] = []
    private var lastAt: TimeInterval = -1

    init(interval: TimeInterval, capacity: Int) {
        self.interval = interval
        self.capacity = capacity
    }

    func push(_ v: Double, at t: TimeInterval) {
        if lastAt < 0 || t - lastAt >= interval {
            values.append(v)
            lastAt = t
            if values.count > capacity {
                values.removeFirst(values.count - capacity)
            }
        }
    }
}

struct MetricSeries {
    let s60 = Series(interval: 2, capacity: 30)     // 60 秒，2 秒一点
    let s5 = Series(interval: 10, capacity: 30)     // 5 分钟，10 秒一点
    let h1 = Series(interval: 60, capacity: 60)     // 1 小时，1 分钟一点
    let h24 = Series(interval: 600, capacity: 144)  // 24 小时，10 分钟一点

    func push(_ v: Double, at t: TimeInterval) {
        s60.push(v, at: t)
        s5.push(v, at: t)
        h1.push(v, at: t)
        h24.push(v, at: t)
    }

    func values(for range: TimeRange) -> [Double] {
        switch range {
        case .m1: return s60.values
        case .m5: return s5.values
        case .h1: return h1.values
        case .h24: return h24.values
        }
    }
}

// MARK: - 告警

struct AlertEvent: Identifiable, Equatable {
    enum Level { case warn, danger }

    let id = UUID()
    let title: String
    let detail: String
    let level: Level
    let at = Date()

    static func == (a: AlertEvent, b: AlertEvent) -> Bool { a.id == b.id }
}

// MARK: - 格式化工具

enum AppInfo {
    /// 版本号只写在 Info.plist 一处，界面和菜单都读它
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}

enum Fmt {
    static func bytes(_ v: UInt64) -> String {
        let d = Double(v)
        let gb = d / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f", gb) }
        let mb = d / 1_048_576
        if mb >= 1 { return String(format: "%.0f", mb) }
        return "0"
    }

    static func bytesUnit(_ v: UInt64) -> String {
        let d = Double(v)
        if d >= 1_073_741_824 { return "GB" }
        return "MB"
    }

    /// 带单位的完整体积，例如 "0.5 GB" / "524 MB"
    static func size(_ v: UInt64) -> String {
        let d = Double(v)
        if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
        return String(format: "%.0f MB", d / 1_048_576)
    }

    /// 强制以 GB 为单位（内存/磁盘场景，避免 MB 数值被误读成 GB）
    static func gb(_ v: UInt64) -> String {
        String(format: "%.1f GB", Double(v) / 1_073_741_824)
    }

    /// 只要数字部分，用于和自定义单位拼接
    static func gbValue(_ v: UInt64) -> String {
        String(format: "%.1f", Double(v) / 1_073_741_824)
    }

    /// 速率：自动选择 KB/s 或 MB/s
    static func rate(_ bps: Double) -> (String, String) {
        if bps >= 1_048_576 {
            return (String(format: "%.1f", bps / 1_048_576), "MB/s")
        }
        if bps >= 1024 {
            return (String(format: "%.0f", bps / 1024), "KB/s")
        }
        return ("0", "KB/s")
    }

    static func duration(_ minutes: Int) -> String {        if minutes < 0 { return "—" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        return "\(h)h \(String(format: "%02d", m))m"
    }

    static func pct(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", v)
    }
}
