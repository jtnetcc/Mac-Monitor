import Foundation
import IOKit

// MARK: - 温度传感器（IOHIDEventSystemClient）
//
// Apple Silicon 上温度不走 AppleSMC（实测 F0Ac/TC0P 等键全部返回空），
// 要走 IOHIDEventSystemClient 匹配 PrimaryUsagePage 0xff00 / PrimaryUsage 5 的私有服务。
// 这些是私有符号，只能 dlsym 动态取，且必须在运行时判空，取不到就整体降级。

final class SensorCollector {

    private typealias CreateFn      = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchFn    = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopySvcFn     = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropFn    = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn   = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn    = @convention(c) (CFTypeRef, Int32) -> Double

    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    /// 必须长期持有：client 一旦被释放，services 句柄就失效，
    /// 后续 CopyEvent 会读到 0 甚至直接 CFRelease 崩溃。
    private var client: CFTypeRef?
    private var sensors: [(name: String, ref: CFTypeRef)] = []
    private var available = false
    private var didSetup = false

    private static let tempEventType: Int64 = 15   // kIOHIDEventTypeTemperature

    /// 注意：必须在实际采样的那条串行队列上初始化。
    /// 实测在主线程创建 client、再到后台队列读事件会拿不到数据（返回 0）。
    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true

        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let pCreate = dlsym(h, "IOHIDEventSystemClientCreate"),
              let pSetMatch = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let pCopySvc = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let pCopyProp = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let pCopyEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let pGetFloat = dlsym(h, "IOHIDEventGetFloatValue") else { return }

        let create = unsafeBitCast(pCreate, to: CreateFn.self)
        let setMatch = unsafeBitCast(pSetMatch, to: SetMatchFn.self)
        let copySvc = unsafeBitCast(pCopySvc, to: CopySvcFn.self)
        let copyProp = unsafeBitCast(pCopyProp, to: CopyPropFn.self)
        copyEvent = unsafeBitCast(pCopyEvent, to: CopyEventFn.self)
        getFloat = unsafeBitCast(pGetFloat, to: GetFloatFn.self)

        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = c
        setMatch(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let list = copySvc(c)?.takeRetainedValue() as? [CFTypeRef] else { return }

        var found: [(String, CFTypeRef)] = []
        for svc in list {
            guard let nameRef = copyProp(svc, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String else { continue }
            // 只保留有用的几个，省得每次遍历全部服务
            if name.hasPrefix("PMU tdie") || name.hasPrefix("GPU MTR Temp")
                || name.hasPrefix("SOC MTR Temp") || name.hasPrefix("NAND") {
                found.append((name, svc))
            }
        }
        sensors = found
        available = !found.isEmpty
    }

    var isAvailable: Bool { available }

    func sample() -> SensorSample {
        var s = SensorSample()
        s.thermalState = ProcessInfo.processInfo.thermalState

        setupIfNeeded()
        guard available, let copyEvent, let getFloat else { return s }

        var cpuTemps: [Double] = []
        var gpuTemps: [Double] = []
        var socTemps: [Double] = []

        for (name, ref) in sensors {
            guard let ev = copyEvent(ref, Self.tempEventType, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, Int32(Self.tempEventType) << 16)
            guard v > 1, v < 150 else { continue }

            if name.hasPrefix("PMU tdie") {
                cpuTemps.append(v)
            } else if name.hasPrefix("GPU MTR Temp") {
                gpuTemps.append(v)
            } else if name.hasPrefix("SOC MTR Temp") {
                socTemps.append(v)
            } else if name.hasPrefix("NAND") {
                s.ssdTemp = v
            }
        }

        if !cpuTemps.isEmpty { s.cpuTemp = cpuTemps.reduce(0, +) / Double(cpuTemps.count) }
        if !gpuTemps.isEmpty { s.gpuTemp = gpuTemps.reduce(0, +) / Double(gpuTemps.count) }
        if !socTemps.isEmpty { s.socTemp = socTemps.reduce(0, +) / Double(socTemps.count) }
        return s
    }
}

// MARK: - GPU（IOAccelerator）

final class GPUCollector {
    func sample() -> GPUSample {
        var s = GPUSample()
        guard let matching = IOServiceMatching("IOAccelerator") else { return s }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return s
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                if let v = perf["Device Utilization %"] as? NSNumber {
                    s.utilization = v.doubleValue
                }
                if let v = perf["In use system memory"] as? NSNumber {
                    s.memUsed = v.uint64Value
                }
                s.available = true
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return s
    }
}
