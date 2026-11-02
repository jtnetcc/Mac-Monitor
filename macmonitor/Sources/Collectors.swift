import Foundation
import AppKit
import Darwin
import IOKit
import SystemConfiguration
import IOKit.ps

// MARK: - CPU
//
// 数据源：host_processor_info(PROCESSOR_CPU_LOAD_INFO)
// 注意：Apple Silicon 上 E 核编号在前、P 核在后。
// 已实测（M1 4P+4E）：4 个满载线程时 core 4-7 达到 99%，core 0-3 仅 30-90% 溢出负载。

final class CPUCollector {
    private var prevBusy: [Double] = []
    private var prevIdle: [Double] = []
    private let pCount: Int
    private let coreCount: Int

    init() {
        pCount = Sysctl.int("hw.perflevel0.logicalcpu")
        coreCount = Sysctl.int("hw.ncpu")
    }

    /// P 核数量（物理性能核）
    var performanceCoreCount: Int { pCount }
    var totalCoreCount: Int { coreCount }

    func sample() -> CPUSample {
        var s = CPUSample()
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            s.load1 = loads[0]; s.load5 = loads[1]; s.load15 = loads[2]
        }

        guard let (busy, idle, n) = readTicks() else { return s }

        if prevBusy.count == n {
            var perCore: [Double] = []
            var totBusy = 0.0, totIdle = 0.0
            for i in 0..<n {
                let db = busy[i] - prevBusy[i]
                let di = idle[i] - prevIdle[i]
                let t = db + di
                perCore.append(t > 0 ? max(0, min(100, db / t * 100)) : 0)
                totBusy += max(0, db)
                totIdle += max(0, di)
            }
            s.perCore = perCore
            let total = totBusy + totIdle
            s.total = total > 0 ? totBusy / total * 100 : 0

            // P 核在后 pCount 个，E 核在前
            let eCount = n - min(pCount, n)
            if eCount > 0 {
                s.eAvg = perCore[0..<eCount].reduce(0, +) / Double(eCount)
            }
            if pCount > 0 && pCount <= n {
                s.pAvg = perCore[eCount..<n].reduce(0, +) / Double(pCount)
            }
            // user/system 拆分：这里用总忙闲比近似，细分需要单独取 CPU_STATE 增量
            s.user = s.total
            s.system = 0
        }

        prevBusy = busy
        prevIdle = idle
        return s
    }

    private func readTicks() -> ([Double], [Double], Int)? {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let ptr = info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: ptr),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let n = Int(cpuCount)
        var busy = [Double](repeating: 0, count: n)
        var idle = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let base = i * Int(CPU_STATE_MAX)
            busy[i] = Double(ptr[base + Int(CPU_STATE_USER)])
                    + Double(ptr[base + Int(CPU_STATE_SYSTEM)])
                    + Double(ptr[base + Int(CPU_STATE_NICE)])
            idle[i] = Double(ptr[base + Int(CPU_STATE_IDLE)])
        }
        return (busy, idle, n)
    }
}

// MARK: - 内存

final class MemoryCollector {
    private let pageSize: UInt64 = UInt64(vm_kernel_page_size)
    private let total: UInt64 = ProcessInfo.processInfo.physicalMemory

    func sample() -> MemorySample {
        var s = MemorySample()
        s.total = total

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let active = UInt64(stats.active_count) * pageSize
            let inactive = UInt64(stats.inactive_count) * pageSize
            let wired = UInt64(stats.wire_count) * pageSize
            let compressed = UInt64(stats.compressor_page_count) * pageSize
            let speculative = UInt64(stats.speculative_count) * pageSize
            let free = UInt64(stats.free_count) * pageSize

            s.wired = wired
            s.compressed = compressed
            s.used = active + wired + compressed
            s.cached = inactive + speculative
            s.free = free
            if s.used > total { s.used = total }
        }

        s.pressure = Int(Sysctl.int32("kern.memorystatus_vm_pressure_level"))

        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            s.swapUsed = xsw.xsu_used
            s.swapTotal = xsw.xsu_total
        }
        return s
    }
}

// MARK: - 网络

final class NetworkCollector {
    private var prevDown: UInt64 = 0
    private var prevUp: UInt64 = 0
    private var prevTime: TimeInterval = 0

    func sample() -> NetworkSample {
        var s = NetworkSample()
        var down: UInt64 = 0
        var up: UInt64 = 0
        var primary = ""

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return s }
        defer { freeifaddrs(ifaddr) }

        var cur = first
        while true {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let raw = ifa.ifa_data, !name.hasPrefix("lo") {
                let d = raw.assumingMemoryBound(to: if_data.self).pointee
                down += UInt64(d.ifi_ibytes)
                up += UInt64(d.ifi_obytes)
                if name.hasPrefix("en") && primary.isEmpty { primary = name }
            }
            guard let next = ifa.ifa_next else { break }
            cur = next
        }

        s.totalDown = down
        s.totalUp = up
        s.interfaceName = primary

        let now = Date().timeIntervalSince1970
        if prevTime > 0, down >= prevDown, up >= prevUp {
            let dt = now - prevTime
            if dt > 0.1 {
                s.down = Double(down - prevDown) / dt
                s.up = Double(up - prevUp) / dt
            }
        }
        prevDown = down
        prevUp = up
        prevTime = now
        return s
    }
}

// MARK: - 磁盘

final class DiskCollector {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevTime: TimeInterval = 0

    func sample() -> DiskSample {
        var s = DiskSample()

        var fs = statfs()
        if statfs("/", &fs) == 0 {
            let bs = UInt64(fs.f_bsize)
            s.total = UInt64(fs.f_blocks) * bs
            s.free = UInt64(fs.f_bavail) * bs
            s.used = s.total > s.free ? s.total - s.free : 0
            s.blockSize = bs
            s.fsType = withUnsafePointer(to: fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
        }

        if let (r, w) = Self.ioTotals() {
            let now = Date().timeIntervalSince1970
            if prevTime > 0, r >= prevRead, w >= prevWrite {
                let dt = now - prevTime
                if dt > 0.1 {
                    s.readBps = Double(r - prevRead) / dt
                    s.writeBps = Double(w - prevWrite) / dt
                }
            }
            prevRead = r; prevWrite = w; prevTime = now
        }
        return s
    }

    /// 从 IORegistry 汇总所有 IOBlockStorageDriver 的累计读写字节数
    static func ioTotals() -> (UInt64, UInt64)? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let v = stats["Bytes (Read)"] as? NSNumber { totalRead += v.uint64Value }
                if let v = stats["Bytes (Write)"] as? NSNumber { totalWrite += v.uint64Value }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (totalRead, totalWrite)
    }
}

// MARK: - 电池

final class BatteryCollector {
    /// 系统报告的健康度（一次性读取）。
    /// 说明：用 AppleRawMaxCapacity/DesignCapacity 自己算会得到 80%，而系统设置显示 88%，
    /// 因为 Apple 对容量做了平滑/校准。为避免与系统数字打架，这里直接读系统值。
    private var systemHealth: Double = 0

    func loadSystemHealthOnce() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPPowerDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["SPPowerDataType"] as? [[String: Any]] else { return }

            for item in arr {
                guard let hi = item["sppower_battery_health_info"] as? [String: Any] else { continue }
                if let cap = hi["sppower_battery_health_maximum_capacity"] as? String {
                    let v = Double(cap.replacingOccurrences(of: "%", with: "")) ?? 0
                    if v > 0 { self?.systemHealth = v / 100 }
                }
            }
        }
    }

    func sample() -> BatterySample {
        var s = BatterySample()

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?
                        .takeUnretainedValue() as? [String: Any] else { continue }

                if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                   let maxCap = desc[kIOPSMaxCapacityKey] as? Int, maxCap > 0 {
                    s.percent = Int(Double(cur) / Double(maxCap) * 100)
                    s.available = true
                }
                s.charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                let state = (desc[kIOPSPowerSourceStateKey] as? String) ?? ""
                s.pluggedIn = (state == kIOPSACPowerValue)

                if s.charging {
                    s.minutesRemaining = (desc[kIOPSTimeToFullChargeKey] as? Int) ?? -1
                } else {
                    s.minutesRemaining = (desc[kIOPSTimeToEmptyKey] as? Int) ?? -1
                }
                break
            }
        }

        // 电池健康度与循环次数
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            let design = Self.prop(service, "DesignCapacity")
            var maxCap = Self.prop(service, "AppleRawMaxCapacity")
            if maxCap == 0 { maxCap = Self.prop(service, "MaxCapacity") }
            if design > 0 && maxCap > 0 {
                s.health = min(1.0, Double(maxCap) / Double(design))
            }
            s.designCapacity = Double(design)
            s.fullCapacity = Double(maxCap)
            s.cycles = Int(Self.prop(service, "CycleCount"))
        }

        if systemHealth > 0 {
            s.health = systemHealth
        }
        return s
    }

    private static func prop(_ svc: io_service_t, _ key: String) -> Int64 {
        guard let ref = IORegistryEntryCreateCFProperty(svc, key as CFString,
                                                        kCFAllocatorDefault, 0) else { return 0 }
        return (ref.takeRetainedValue() as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - 进程
//
// 一次遍历拿全部进程（约 600 个），返回按 CPU 降序的完整列表，
// 由 UI 自己 prefix —— 面板取 4 行、详情窗口取 12 行、进程页全量。
// 这样进程页的搜索/排序不用再单独采样一轮。

final class ProcessCollector {
    private var prevCPU: [Int32: UInt64] = [:]
    private var prevTime: UInt64 = 0
    /// pid → 可执行文件全路径。proc_pidpath 每个进程一次 syscall，
    /// 长尾进程靠缓存省掉；pid 会被复用，所以每轮都按存活 pid 修剪。
    private var pathCache: [Int32: String] = [:]
    /// pid → 身份信息（用户 / 启动时间 / 原始名）。这些字段进程一生不变，
    /// 缓存后每轮只需一次 PROC_PIDTASKINFO，省掉一次 PROC_PIDTBSDINFO。
    private var identityCache: [Int32: Identity] = [:]
    private var userCache: [UInt32: String] = [:]

    private struct Identity {
        let uid: UInt32
        let user: String
        let start: Date?
        let isSystem: Bool
        let rawName: String
    }

    /// 解析完整路径的进程数上限（按 CPU/内存排序取前 N）
    private let pathResolveLimit = 120

    func sample() -> [ProcSample] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = proc_listallpids(&pids, Int32(8192 * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }

        let now = DispatchTime.now().uptimeNanoseconds
        let dt = prevTime > 0 ? Double(now - prevTime) : 0

        var results: [ProcSample] = []
        var newCPU: [Int32: UInt64] = [:]
        var live = Set<Int32>()
        results.reserveCapacity(Int(n))
        live.reserveCapacity(Int(n))

        for i in 0..<Int(n) {
            let pid = pids[i]
            if pid <= 0 { continue }
            live.insert(pid)

            var s = ProcSample(pid: pid, name: "", cpu: 0, mem: 0)

            // 非特权进程读不到 root daemon 的 taskinfo（EPERM），
            // 此时退化成「只有身份、没有指标」，照样列出来
            var info = proc_taskinfo()
            let sz = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz {
                let cpuTime = info.pti_total_user &+ info.pti_total_system
                newCPU[pid] = cpuTime
                if dt > 0, let old = prevCPU[pid], cpuTime >= old {
                    s.cpu = Double(cpuTime - old) / dt * 100
                }
                s.mem = info.pti_resident_size
                s.threads = Int(info.pti_threadnum)
                s.hasMetrics = true
            } else {
                s.hasMetrics = false
            }

            if let cached = identityCache[pid] {
                s.uid = cached.uid
                s.user = cached.user
                s.start = cached.start
                s.isSystem = cached.isSystem
                s.name = cached.rawName
            } else {
                var bsd = proc_bsdinfo()
                let bsz = Int32(MemoryLayout<proc_bsdinfo>.size)
                var name = ""
                var uid: UInt32 = 0
                var start: Date?
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsz) == bsz {
                    uid = bsd.pbi_uid
                    if bsd.pbi_start_tvsec > 0 {
                        start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
                    }
                    // pbi_name 有 32 字节，比 proc_name 的 16 字节宽，先用它兜底
                    name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
                        guard let base = raw.baseAddress else { return "" }
                        return String(cString: base.assumingMemoryBound(to: CChar.self))
                    }
                }
                if name.isEmpty {
                    var buf = [CChar](repeating: 0, count: 256)
                    proc_name(pid, &buf, 256)
                    name = String(cString: buf)
                }

                var user: String
                if let cached = userCache[uid] {
                    user = cached
                } else {
                    user = ProcessActions.userName(uid)
                    userCache[uid] = user
                }

                s.uid = uid
                s.user = user
                s.start = start
                s.isSystem = uid < 500
                s.name = name
                identityCache[pid] = Identity(uid: uid, user: user, start: start,
                                               isSystem: s.isSystem, rawName: name)
            }
            if s.name.isEmpty { continue }

            results.append(s)
        }

        prevCPU = newCPU
        prevTime = now

        // 缓存按存活 pid 修剪：pid 会被复用，留着旧条目会张冠李戴
        if !pathCache.isEmpty {
            pathCache = pathCache.filter { live.contains($0.key) }
        }
        if !identityCache.isEmpty {
            identityCache = identityCache.filter { live.contains($0.key) }
        }

        results.sort(by: ProcSample.byCPU)

        // 只给最靠前的一批解析完整可执行文件名：
        // proc_name 会被内核截断成 "Google Chrome Helper (Aperitif"
        let resolveCount = min(results.count, pathResolveLimit)
        for i in 0..<resolveCount {
            let pid = results[i].pid
            if let cached = pathCache[pid] {
                results[i].path = cached
            } else if let p = ProcessActions.pathOf(pid) {
                results[i].path = p
                pathCache[pid] = p
            }
            if !results[i].path.isEmpty {
                let base = (results[i].path as NSString).lastPathComponent
                if !base.isEmpty { results[i].name = base }
            }
        }

        return results
    }
}

// MARK: - 机器配置
//
// 大部分走 sysctl / IOKit，毫秒级；只有「型号名称」和「内存类型」需要
// system_profiler（约 0.2 秒），所以拆成同步 + 异步两段，避免启动卡顿。

final class SystemInfoCollector {

    /// 主线程调用，只做快速取值
    func loadLocal() -> SystemInfo {
        var s = SystemInfo()
        s.modelIdentifier = Sysctl.string("hw.model")
        s.chip = Sysctl.string("machdep.cpu.brand_string")
        s.arch = Sysctl.string("hw.machine")
        s.totalCores = Sysctl.int("hw.ncpu")
        s.pCores = Sysctl.int("hw.perflevel0.logicalcpu")
        s.eCores = Sysctl.int("hw.perflevel1.logicalcpu")
        s.memoryBytes = ProcessInfo.processInfo.physicalMemory
        // kern.hostname 可能被设成 IP，优先用 SCPreferences 的 LocalHostName
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty {
            s.hostname = local
        } else {
            let raw = Sysctl.string("kern.hostname")
            s.hostname = raw.isEmpty ? ProcessInfo.processInfo.hostName : raw
        }
        s.localIP = Self.primaryIPv4()
        s.osBuild = Sysctl.string("kern.osversion")

        let v = ProcessInfo.processInfo.operatingSystemVersion
        s.osVersion = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"

        s.bootTime = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        s.serial = Self.serialNumber()

        if let screen = NSScreen.main {
            let f = screen.frame
            let scale = screen.backingScaleFactor
            s.displayScale = Int(scale)
            s.displayPoints = "\(Int(f.width)) × \(Int(f.height)) pt"
            s.displayPixels = "\(Int(f.width * scale)) × \(Int(f.height * scale)) px"
        }
        return s
    }

    /// 后台调用，补全需要 system_profiler 的两项
    func loadProfiler(completion: @escaping (String, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPHardwareDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["SPHardwareDataType"] as? [[String: Any]],
                  let first = arr.first else { return }

            let name = (first["machine_name"] as? String) ?? ""
            let mem = (first["physical_memory"] as? String) ?? ""
            completion(name, mem)
        }
    }

    /// 主网卡 IPv4 地址
    private static func primaryIPv4() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "—" }
        defer { freeifaddrs(ifaddr) }
        var result = "—"
        var cur = first
        while true {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") {
                        result = ip
                        break
                    }
                }
            }
            guard let next = ifa.ifa_next else { break }
            cur = next
        }
        return result
    }

    /// 序列号：IOPlatformExpertDevice 的 IOPlatformSerialNumber
    private static func serialNumber() -> String {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return "—" }
        defer { IOObjectRelease(svc) }
        guard let ref = IORegistryEntryCreateCFProperty(svc, "IOPlatformSerialNumber" as CFString,
                                                        kCFAllocatorDefault, 0) else { return "—" }
        return (ref.takeRetainedValue() as? String) ?? "—"
    }
}

// MARK: - sysctl 辅助

enum Sysctl {
    static func int(_ name: String) -> Int {
        var val: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname(name, &val, &size, nil, 0)
        return Int(val)
    }

    static func int32(_ name: String) -> Int32 {
        var val: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname(name, &val, &size, nil, 0)
        return val
    }

    static func string(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }
}
