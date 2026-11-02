import Foundation
import Combine

// MARK: - 告警阈值

struct Thresholds {
    var cpuPercent: Double = 85
    var cpuDuration: TimeInterval = 60
    var diskFreeGB: Double = 10
    var tempC: Double = 90
    var cooldown: TimeInterval = 600      // 同一告警冷却期，避免刷屏
}

final class MetricsStore: ObservableObject {
    // 实时快照
    @Published var cpu = CPUSample()
    @Published var memory = MemorySample()
    @Published var network = NetworkSample()
    @Published var disk = DiskSample()
    @Published var battery = BatterySample()
    @Published var sensor = SensorSample()
    @Published var gpu = GPUSample()
    @Published var sysInfo = SystemInfo()
    /// 全部进程，按 CPU 降序（UI 自己 prefix）
    @Published var processes: [ProcSample] = []
    @Published var alert: AlertEvent?
    /// 一次性操作反馈
    @Published var toast: Toast?
    /// 详情窗口当前分区
    @Published var windowSection: Section = .overview

    /// 菜单栏显示哪个指标（持久化到 UserDefaults，只有这一条偏好）
    @Published var statusMetric: StatusMetric = {
        let raw = UserDefaults.standard.string(forKey: "statusMetric") ?? ""
        return StatusMetric(rawValue: raw) ?? .cpu
    }() {
        didSet { UserDefaults.standard.set(statusMetric.rawValue, forKey: "statusMetric") }
    }

    // 多分辨率历史
    let cpuSeries = MetricSeries()
    let memSeries = MetricSeries()
    let netDownSeries = MetricSeries()
    let netUpSeries = MetricSeries()
    let diskRSeries = MetricSeries()
    let diskWSeries = MetricSeries()
    let tempSeries = MetricSeries()

    let coreCount: Int
    let pCoreCount: Int
    let machineName: String
    let chipName: String

    var thresholds = Thresholds()

    private let cpuC = CPUCollector()
    private let memC = MemoryCollector()
    private let netC = NetworkCollector()
    private let diskC = DiskCollector()
    private let batC = BatteryCollector()
    private let procC = ProcessCollector()
    private let sensorC = SensorCollector()
    private let sysC = SystemInfoCollector()
    private let gpuC = GPUCollector()

    private var timer: Timer?
    private var tick = 0
    private let queue = DispatchQueue(label: "com.macmonitor.sample", qos: .utility)
    private var startedAt = Date().timeIntervalSince1970
    var samplingInterval: TimeInterval = 2.0

    // 告警内部状态
    private var cpuHighSince: TimeInterval?
    private var lastFired: [String: TimeInterval] = [:]

    var panelVisible = false {
        didSet { restartTimer() }
    }

    init() {
        coreCount = cpuC.totalCoreCount
        pCoreCount = cpuC.performanceCoreCount
        let brand = Sysctl.string("machdep.cpu.brand_string")
        chipName = brand.isEmpty ? "Apple Silicon" : brand
        machineName = Sysctl.string("hw.model")
    }

    func start() {
        batC.loadSystemHealthOnce()
        loadSystemInfo()
        startedAt = Date().timeIntervalSince1970
        restartTimer()
    }

    /// 机器配置：快的部分主线程取，system_profiler 那两项异步补
    private func loadSystemInfo() {
        sysInfo = sysC.loadLocal()
        sysC.loadProfiler { [weak self] name, mem in
            DispatchQueue.main.async {
                guard let self else { return }
                if !name.isEmpty { self.sysInfo.modelName = name }
                if !mem.isEmpty { self.sysInfo.memoryType = mem }
            }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let iv: TimeInterval = panelVisible ? samplingInterval : max(samplingInterval, 5.0)
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in
            self?.collect()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        collect()
    }

    private func collect() {
        tick += 1
        let doSlow = (tick % 3 == 0) || tick == 1
        let doProc = (tick % 2 == 0) || tick == 1
        let doSensor = (tick % 2 == 0) || tick == 1

        queue.async { [weak self] in
            guard let self else { return }
            let cpu = self.cpuC.sample()
            let mem = self.memC.sample()
            let net = self.netC.sample()
            let disk = self.diskC.sample()
            let bat = doSlow ? self.batC.sample() : nil
            let procs = doProc ? self.procC.sample() : nil
            let gpu = doSensor ? self.gpuC.sample() : nil

            DispatchQueue.main.async {
                let now = Date().timeIntervalSince1970
                let t = now - self.startedAt

                // IOHIDEventSystemClient 必须在主线程访问：
                // 放到后台队列会读回 0，甚至在创建阶段被系统 SIGKILL。
                // 温度采样只有十几个传感器，主线程开销可忽略。
                let sensor = doSensor ? self.sensorC.sample() : nil

                self.cpu = cpu
                self.memory = mem
                self.network = net
                self.disk = disk
                if let bat { self.battery = bat }
                if let procs { self.processes = procs }
                if let sensor {
                    self.sensor = sensor
                    if sensor.cpuTemp > 0 { self.tempSeries.push(sensor.cpuTemp, at: t) }
                }
                if let gpu { self.gpu = gpu }

                self.cpuSeries.push(cpu.total, at: t)
                self.memSeries.push(mem.ratio * 100, at: t)
                self.netDownSeries.push(net.down, at: t)
                self.netUpSeries.push(net.up, at: t)
                self.diskRSeries.push(disk.readBps, at: t)
                self.diskWSeries.push(disk.writeBps, at: t)

                self.evaluateAlerts(now: now)
            }
        }
    }

    // MARK: 告警

    private func evaluateAlerts(now: TimeInterval) {
        let th = thresholds

        // 1. CPU 持续高负载
        if cpu.total >= th.cpuPercent {
            if cpuHighSince == nil { cpuHighSince = now }
        } else {
            cpuHighSince = nil
        }
        if let since = cpuHighSince, now - since >= th.cpuDuration, canFire("cpu", now) {
            cpuHighSince = nil
            fire(AlertEvent(title: "CPU 持续高负载",
                            detail: "已超过 \(Int(th.cpuPercent))% 持续 \(Int(th.cpuDuration)) 秒",
                            level: .warn), now: now, key: "cpu")
            return
        }

        // 2. 内存压力
        if memory.pressure >= 2, canFire("mem", now) {
            fire(AlertEvent(title: "内存压力偏高",
                            detail: "系统内存压力进入「\(memory.pressureText)」，Swap \(Fmt.bytes(memory.swapUsed)) GB",
                            level: memory.pressure >= 4 ? .danger : .warn), now: now, key: "mem")
            return
        }

        // 3. 磁盘空间
        let freeGB = Double(disk.free) / 1_073_741_824
        if disk.total > 0, freeGB < th.diskFreeGB, canFire("disk", now) {
            fire(AlertEvent(title: "磁盘空间不足",
                            detail: String(format: "剩余 %.1f GB，低于阈值 %.0f GB", freeGB, th.diskFreeGB),
                            level: .danger), now: now, key: "disk")
            return
        }

        // 4. 温度
        if sensor.cpuTemp > th.tempC, canFire("temp", now) {
            fire(AlertEvent(title: "CPU 温度过高",
                            detail: String(format: "当前 %.0f°C，超过阈值 %.0f°C", sensor.cpuTemp, th.tempC),
                            level: .danger), now: now, key: "temp")
            return
        }
    }

    private func canFire(_ key: String, _ now: TimeInterval) -> Bool {
        guard let last = lastFired[key] else { return true }
        return now - last >= thresholds.cooldown
    }

    private func fire(_ event: AlertEvent, now: TimeInterval, key: String) {
        lastFired[key] = now
        alert = event
        let id = event.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if self?.alert?.id == id { self?.alert = nil }
        }
    }

    func dismissAlert() {
        alert = nil
    }

    // MARK: 进程操作

    /// 结束 / 强制结束进程。系统进程和强制结束都要二次确认。
    func terminate(_ p: ProcSample, force: Bool) {
        if let why = ProcessActions.blockedReason(p) {
            showToast(why, ok: false)
            return
        }

        if force || p.isSystem {
            let title = "\(force ? "强制结束" : "结束") \(p.name)？"
            let detail = force
                ? "PID \(p.pid) · 进程会被立即杀死，未保存的数据将丢失。"
                : "PID \(p.pid) · 这是 \(p.user) 的系统进程，结束可能影响系统功能。"
            guard ProcessActions.confirm(title: title, message: detail,
                                         okTitle: force ? "强制结束" : "结束",
                                         destructive: force) else { return }
        }

        apply(ProcessActions.kill(p.pid, force: force), to: p, force: force)
    }

    private func apply(_ outcome: KillOutcome, to p: ProcSample, force: Bool) {
        let verb = force ? "强制结束" : "结束"
        switch outcome {
        case .ok:
            removeProcess(p.pid)
            showToast("已\(verb) \(p.name)（\(p.pid)）")
        case .gone:
            removeProcess(p.pid)
            showToast("\(p.name) 已经退出", ok: false)
        case .needsAdmin:
            showToast("需要管理员权限，请在弹窗中授权…")
            ProcessActions.killWithAdmin(p.pid, force: force) { [weak self] ok in
                guard let self else { return }
                if ok {
                    self.removeProcess(p.pid)
                    self.showToast("已\(verb) \(p.name)（\(p.pid)）")
                } else {
                    self.showToast("授权取消或失败，未能结束 \(p.name)", ok: false)
                }
            }
        case .blocked(let msg):
            showToast(msg, ok: false)
        case .failed(let msg):
            showToast("结束失败：\(msg)", ok: false)
        }
    }

    private func removeProcess(_ pid: Int32) {
        processes.removeAll { $0.pid == pid }
    }

    // MARK: 提示条

    func showToast(_ text: String, ok: Bool = true) {
        let t = Toast(text: text, ok: ok)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }
}
