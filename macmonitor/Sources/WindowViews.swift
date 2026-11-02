import SwiftUI

// MARK: - 深色主题（专业监控工具调性）

enum Dark {
    static let bg        = Color(hex: 0x0B0D11)
    static let sidebar   = Color(hex: 0x0E1016)
    static let panel     = Color(hex: 0x15181F)
    static let panelHead = Color(hex: 0x1A1E26)
    static let border    = Color.white.opacity(0.065)
    static let text      = Color.white.opacity(0.94)
    static let dim       = Color.white.opacity(0.58)
    static let faint     = Color.white.opacity(0.40)

    static let blue   = Color(hex: 0x4C9AFF)
    static let green  = Color(hex: 0x39D98A)
    static let amber  = Color(hex: 0xFFA726)
    static let red    = Color(hex: 0xFF5C5C)
    static let purple = Color(hex: 0xA78BFA)
    static let teal   = Color(hex: 0x2DD4BF)

    static func load(_ v: Double) -> Color {
        if v >= 90 { return red }
        if v >= 70 { return amber }
        return blue
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - 分区

enum Section: String, CaseIterable, Identifiable {
    case overview = "概览"
    case cpu = "CPU"
    case memory = "内存"
    case process = "进程"
    case disk = "磁盘"
    case network = "网络"
    case sensor = "传感器"
    case system = "系统"
    case software = "软件"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .process: return "list.bullet.rectangle"
        case .disk: return "internaldrive"
        case .network: return "arrow.up.arrow.down"
        case .sensor: return "thermometer.medium"
        case .system: return "desktopcomputer"
        case .software: return "shippingbox"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "全部指标总览"
        case .cpu: return "处理器占用与每核负载"
        case .memory: return "内存占用与交换分区"
        case .process: return "全部进程 · 右键结束"
        case .disk: return "容量与读写吞吐"
        case .network: return "上下行速率与累计流量"
        case .sensor: return "温度、散热与 GPU"
        case .system: return "设备型号与系统版本"
        case .software: return "安装 · 卸载 · 残留清理"
        }
    }

    /// 命令行 / 调试参数用："process" → .process
    static func named(_ name: String) -> Section {
        switch name.lowercased() {
        case "cpu": return .cpu
        case "memory", "mem": return .memory
        case "process", "procs": return .process
        case "software", "manager", "apps": return .software
        case "disk": return .disk
        case "network", "net": return .network
        case "sensor": return .sensor
        case "system": return .system
        default: return .overview
        }
    }
}

// MARK: - 主窗口

struct MonitorWindowView: View {
    @ObservedObject var store: MetricsStore
    /// 截图模式：ImageRenderer 渲染不出 ScrollView 里的内容，
    /// 所以导出 PNG 时改用扁平列表 + 只取前若干行
    var snapshotMode: Bool = false
    @State private var range: TimeRange = .m1
    @State private var procQuery = ""
    @State private var procSort: ProcSort = .cpu
    @State private var detailProc: ProcSample?
    /// 软件管家的状态由 AppDelegate 持有，窗口关掉再开也不会重新扫盘
    @ObservedObject var manager: ManagerStore

    private var section: Section { store.windowSection }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Dark.border).frame(width: 0.5)
            if section == .software {
                SoftwareView(store: manager)
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                main
            }
        }
        .background(Dark.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1000, minHeight: 640)
        .overlay(alignment: .bottom) {
            // 动画只挂在这层，别挂到整个窗口上——那会让每次数据刷新都走一遍动画事务
            ZStack {
                if let t = store.toast {
                    ToastView(toast: t)
                        .id(t.id)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: store.toast?.id)
        }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Dark.blue.opacity(0.16))
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(Dark.blue)
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mac Monitor").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dark.text)
                    Text("v\(AppInfo.version)").font(.system(size: 9)).foregroundStyle(Dark.faint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 18)

            ForEach(Section.allCases) { s in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { store.windowSection = s }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 15)
                        Text(s.rawValue).font(.system(size: 12, weight: section == s ? .medium : .regular))
                        Spacer()
                    }
                    .foregroundStyle(section == s ? Dark.text : Dark.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(section == s ? Color.white.opacity(0.07) : Color.clear)
                    )
                    .overlay(alignment: .leading) {
                        if section == s {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Dark.blue)
                                .frame(width: 2.5, height: 15)
                                .offset(x: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 1.5)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                sideStat("采样", String(format: "%.1f s", store.samplingInterval))
                sideStat("核心", "\(store.coreCount)（\(store.pCoreCount)P+\(store.coreCount - store.pCoreCount)E）")
                sideStat("芯片", store.chipName)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 152)
        .background(Dark.sidebar)
    }

    private func sideStat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(.system(size: 9)).foregroundStyle(Dark.faint)
            Text(v).font(.system(size: 9, weight: .medium)).foregroundStyle(Dark.dim).lineLimit(1)
        }
    }

    // MARK: 内容区

    private var main: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Dark.text)
                Text(section.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Dark.faint)
            }
            Spacer()

            if section != .system && section != .process {
            HStack(spacing: 2) {
                ForEach(TimeRange.allCases, id: \.self) { r in
                    Button { range = r } label: {
                        Text(r.rawValue)
                            .font(.system(size: 10, weight: range == r ? .medium : .regular))
                            .foregroundStyle(range == r ? Dark.text : Dark.dim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(range == r ? Color.white.opacity(0.09) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview: overviewPage
        case .cpu: cpuPage
        case .memory: memoryPage
        case .process: processPage
        case .disk: diskPage
        case .network: networkPage
        case .sensor: sensorPage
        case .system: systemPage
        // 软件分区在 body 里整块接管，不走这里
        case .software: EmptyView()
        }
    }

    // MARK: 概览

    private var overviewPage: some View {
        VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("CPU", "\(Int(store.cpu.total.rounded()))", "%",
                       Dark.load(store.cpu.total), spark: store.cpuSeries.values(for: .m1), maxV: 100)
                kpiBox("内存", Fmt.gbValue(store.memory.used), "/ \(Fmt.gb(store.memory.total))",
                       Dark.purple, spark: store.memSeries.values(for: .m1), maxV: 100)
                kpiBox("磁盘", "\(Int((store.disk.ratio * 100).rounded()))", "%",
                       Dark.amber, spark: store.diskRSeries.values(for: .m1),
                       maxV: max(store.diskRSeries.values(for: .m1).max() ?? 1, 1024))
                kpiBox("温度", store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—", "°C",
                       tempColor, spark: store.tempSeries.values(for: .m1),
                       maxV: max((store.tempSeries.values(for: .m1).max() ?? 50) + 5, 60))
            }
            .frame(height: 78)

            HStack(spacing: 11) {
                panelBox("CPU 使用率", hint: "\(Int(store.cpu.pAvg.rounded()))% P · \(Int(store.cpu.eAvg.rounded()))% E") {
                    ProChart(values: store.cpuSeries.values(for: range), minV: 0, maxV: 100,
                             color: Dark.blue) { "\(Int($0))%" }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
                panelBox("每核占用", hint: "\(store.coreCount) 核") {
                    CoreBars(cores: store.cpu.perCore, pCount: store.pCoreCount)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                }
                .frame(width: 292)
            }
            .frame(height: 208)

            HStack(spacing: 11) {
                panelBox("进程排行", hint: "按 CPU 排序") {
                    processTable(limit: 10, byMemory: false)
                }
                panelBox("网络 · 传感器", hint: nil) {
                    VStack(spacing: 0) {
                        miniRow("下行", rateText(store.network.down), Dark.green)
                        miniRow("上行", rateText(store.network.up), Dark.blue)
                        miniRow("GPU", store.gpu.available ? String(format: "%.0f%%", store.gpu.utilization) : "—", Dark.teal)
                        miniRow("磁盘读", rateText(store.disk.readBps), Dark.amber)
                        miniRow("磁盘写", rateText(store.disk.writeBps), Dark.purple)
                        miniRow("热压", store.sensor.thermalText, thermalColor)
                        miniRow("内存压力", store.memory.pressureText, pressureColor)
                        miniRow("CPU 温度", store.sensor.cpuTemp > 0 ? String(format: "%.0f°C", store.sensor.cpuTemp) : "—", tempColor)
                    }
                    .padding(.horizontal, 11)
                    .padding(.bottom, 10)
                }
                .frame(width: 292)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: CPU

    private var cpuPage: some View {
        VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("总占用", "\(Int(store.cpu.total.rounded()))", "%", Dark.load(store.cpu.total),
                       spark: store.cpuSeries.values(for: .m1), maxV: 100)
                kpiBox("P 核", "\(Int(store.cpu.pAvg.rounded()))", "%", Dark.blue, spark: [], maxV: 100)
                kpiBox("E 核", "\(Int(store.cpu.eAvg.rounded()))", "%", Dark.teal, spark: [], maxV: 100)
                kpiBox("负载 1 分", String(format: "%.2f", store.cpu.load1), "", Dark.purple, spark: [], maxV: 1)
                kpiBox("温度", store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—",
                       "°C", tempColor, spark: [], maxV: 100)
            }
            .frame(height: 78)

            panelBox("CPU 使用率", hint: "平均 \(Int(avg(store.cpuSeries.values(for: range)).rounded()))% · 峰值 \(Int((store.cpuSeries.values(for: range).max() ?? 0).rounded()))%") {
                ProChart(values: store.cpuSeries.values(for: range), minV: 0, maxV: 100,
                         color: Dark.blue) { "\(Int($0))%" }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .frame(height: 200)

            HStack(spacing: 11) {
                panelBox("每核占用", hint: "E 核 \(store.coreCount - store.pCoreCount) · P 核 \(store.pCoreCount)") {
                    CoreBars(cores: store.cpu.perCore, pCount: store.pCoreCount)
                        .padding(.horizontal, 11)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                }
                panelBox("进程排行", hint: "按 CPU 排序") {
                    processTable(limit: 12, byMemory: false)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var coreList: some View {
        let eCount = max(0, store.cpu.perCore.count - min(store.pCoreCount, store.cpu.perCore.count))
        return HStack(spacing: 6) {
            ForEach(Array(store.cpu.perCore.enumerated()), id: \.offset) { i, v in
                let isP = i >= eCount
                VStack(spacing: 2) {
                    Text(isP ? "P\(i - eCount + 1)" : "E\(i + 1)")
                        .font(.system(size: 8))
                        .foregroundStyle(Dark.faint)
                    Text("\(Int(v.rounded()))")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isP ? Dark.blue : Dark.teal)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 内存

    private var memoryPage: some View {
        VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("已用", Fmt.gbValue(store.memory.used), "/ \(Fmt.gb(store.memory.total))",
                       Dark.purple, spark: store.memSeries.values(for: .m1), maxV: 100)
                kpiBox("缓存", Fmt.gbValue(store.memory.cached), "GB", Dark.blue, spark: [], maxV: 1)
                kpiBox("Wired", Fmt.gbValue(store.memory.wired), "GB", Dark.amber, spark: [], maxV: 1)
                kpiBox("Swap", String(format: "%.1f", Double(store.memory.swapUsed) / 1_073_741_824),
                       "/ \(String(format: "%.1f", Double(store.memory.swapTotal) / 1_073_741_824)) GB",
                       store.memory.swapUsed > 2_000_000_000 ? Dark.amber : Dark.teal, spark: [], maxV: 1)
                kpiBox("压力", store.memory.pressureText, "", pressureColor, spark: [], maxV: 1)
            }
            .frame(height: 78)

            panelBox("内存占用", hint: "平均 \(Int(avg(store.memSeries.values(for: range)).rounded()))%") {
                ProChart(values: store.memSeries.values(for: range), minV: 0, maxV: 100,
                         color: Dark.purple) { "\(Int($0))%" }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .frame(height: 200)

            HStack(spacing: 11) {
                VStack(spacing: 11) {
                    panelBox("组成", hint: "压缩 \(Fmt.gb(store.memory.compressed))（含在已用内）") {
                        VStack(alignment: .leading, spacing: 11) {
                            memBar
                            memLegend

                            Rectangle().fill(Dark.border).frame(height: 0.5)

                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Swap 使用").font(.system(size: 10)).foregroundStyle(Dark.dim)
                                    Spacer()
                                    Text("\(Fmt.gb(store.memory.swapUsed)) / \(Fmt.gb(store.memory.swapTotal))")
                                        .font(.system(size: 10, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(Dark.text)
                                }
                                GeometryReader { geo in
                                    let w = geo.size.width
                                    let ratio = store.memory.swapTotal > 0
                                        ? Double(store.memory.swapUsed) / Double(store.memory.swapTotal) : 0
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.06))
                                        Capsule()
                                            .fill(ratio > 0.6 ? Dark.amber : Dark.teal)
                                            .frame(width: max(3, w * CGFloat(min(1, ratio))))
                                    }
                                }
                                .frame(height: 7)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                    .frame(height: 188)

                    panelBox("内存压力", hint: nil) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                Circle().fill(pressureColor).frame(width: 8, height: 8)
                                Text(store.memory.pressureText)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(pressureColor)
                                Spacer()
                            }
                            Text(pressureHint)
                                .font(.system(size: 9.5))
                                .foregroundStyle(Dark.faint)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.top, 4)
                        .padding(.bottom, 10)
                    }
                }
                panelBox("进程排行", hint: "按内存排序") {
                    processTable(limit: 12, byMemory: true)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var memBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(Double(store.memory.total), 1)
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3).fill(Dark.blue)
                    .frame(width: max(0, w * CGFloat(Double(store.memory.used) / total) - 1))
                RoundedRectangle(cornerRadius: 3).fill(Dark.blue.opacity(0.35))
                    .frame(width: max(0, w * CGFloat(Double(store.memory.cached) / total) - 1))
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.10))
            }
        }
        .frame(height: 9)
    }

    /// 温度区间条：30°C ~ 100°C，用渐变色标出当前温度落在哪一档
    private var tempGauge: some View {
        let t = store.sensor.cpuTemp
        let frac = min(1, max(0, (t - 30) / 70))
        return VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(colors: [Dark.teal, Dark.green, Dark.amber, Dark.red],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .opacity(0.22)
                    Capsule()
                        .fill(
                            LinearGradient(colors: [Dark.teal, Dark.green, Dark.amber, Dark.red],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(4, w * CGFloat(frac)))
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: max(0, min(w - 7, w * CGFloat(frac) - 3.5)))
                }
            }
            .frame(height: 8)

            HStack {
                Text("30°C").font(.system(size: 8)).foregroundStyle(Dark.faint)
                Spacer()
                Text("100°C").font(.system(size: 8)).foregroundStyle(Dark.faint)
            }
        }
    }

    private var pressureHint: String {
        switch store.memory.pressure {
        case 1: return "系统内存充裕，未发生换页压力。缓存会按需自动回收。"
        case 2: return "内存开始吃紧，系统正在压缩内存并回收缓存。8GB 机器上常见。"
        default: return "压力已到危险级别，系统在频繁换页，可能出现明显卡顿。"
        }
    }

    private var memLegend: some View {
        VStack(spacing: 6) {
            legendRow(Dark.blue, "已用", Fmt.gb(store.memory.used))
            legendRow(Dark.blue.opacity(0.35), "缓存", Fmt.gb(store.memory.cached))
            legendRow(Color.white.opacity(0.12), "空闲", Fmt.gb(store.memory.free))
        }
    }

    private func legendRow(_ c: Color, _ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 7, height: 7)
            Text(k).font(.system(size: 10)).foregroundStyle(Dark.dim)
            Spacer()
            Text(v).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Dark.text)
        }
    }

    // MARK: 进程

    /// 过滤 + 排序后的进程列表（约 600 个，排序开销可忽略）
    private var filteredProcesses: [ProcSample] {
        var rows = store.processes
        let q = procQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.name.lowercased().contains(q)
                    || "\($0.pid)" == q
                    || $0.user.lowercased().contains(q)
            }
        }
        switch procSort {
        case .cpu:
            rows.sort(by: ProcSample.byCPU)
        case .mem:
            rows.sort { $0.mem > $1.mem }
        case .name:
            rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid:
            rows.sort { $0.pid < $1.pid }
        }
        return rows
    }

    private var processPage: some View {
        let rows = filteredProcesses
        let totalThreads = store.processes.reduce(0) { $0 + $1.threads }
        let activeCount = store.processes.filter { $0.cpu >= 0.5 }.count
        let cpuTop = store.processes.max { $0.cpu < $1.cpu }
        let memTop = store.processes.max { $0.mem < $1.mem }

        return VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("进程数", "\(store.processes.count)", "", Dark.blue, spark: [], maxV: 1)
                kpiBox("线程数", "\(totalThreads)", "", Dark.teal, spark: [], maxV: 1)
                kpiBox("活跃进程", "\(activeCount)", "", Dark.green, spark: [], maxV: 1)
                kpiBox("最耗 CPU",
                       cpuTop.map { String(format: "%.0f", $0.cpu) } ?? "—",
                       cpuTop.map { "% · \($0.name)" } ?? "",
                       Dark.red, spark: [], maxV: 1)
                kpiBox("最占内存",
                       memTop.map { Fmt.size($0.mem) } ?? "—",
                       "",
                       Dark.purple, spark: [], maxV: 1)
            }
            .frame(height: 78)

            panelBox("进程列表", hint: "共 \(rows.count) 个 · 右键结束 · 单击查看详情") {
                VStack(spacing: 0) {
                    procToolbar
                    procHeader
                    Rectangle().fill(Dark.border).frame(height: 0.5)

                    if rows.isEmpty {
                        Text(store.processes.isEmpty ? "采样中…" : "没有匹配的进程")
                            .font(.system(size: 10))
                            .foregroundStyle(Dark.faint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if snapshotMode {
                        VStack(spacing: 0) { processRows(rows, limit: 16) }
                    } else {
                        // 必须惰性：344 行全部实例化时，每次刷新都要重排整张表，
                        // 实测 CPU 从 8% 飙到 30%、内存从 60MB 涨到 250MB
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                processRows(rows, limit: nil)
                            }
                        }
                    }
                }
            }

            Text("root 拥有的系统 daemon 需要 root 权限才能读取 taskinfo，非特权进程读不到它们的 CPU / 内存，因此未列出")
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $detailProc) { p in
            ProcessDetailSheet(detail: ProcessActions.detail(for: p)) { force in
                store.terminate(p, force: force)
            }
        }
    }

    @ViewBuilder
    private func processRows(_ rows: [ProcSample], limit: Int?) -> some View {
        let shown = limit.map { Array(rows.prefix($0)) } ?? rows
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
            ProcessRowView(
                p: p,
                index: i,
                onKill: { force in store.terminate(p, force: force) },
                onDetail: { detailProc = p }
            )
        }
    }

    private var procToolbar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.faint)
                if snapshotMode {
                    // 截图模式下 TextField 会被 ImageRenderer 抢成第一响应者，
                    // 渲染出一整条黄色焦点环，换成静态占位文字
                    Text("搜索进程名 / PID / 用户")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Dark.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("搜索进程名 / PID / 用户", text: $procQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Dark.text)
                    if !procQuery.isEmpty {
                        Button { procQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Dark.faint)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Dark.border, lineWidth: 0.5)
            )
            .frame(width: 220)

            HStack(spacing: 1) {
                ForEach(ProcSort.allCases) { s in
                    Button { procSort = s } label: {
                        Text(s.rawValue)
                            .font(.system(size: 10, weight: procSort == s ? .medium : .regular))
                            .foregroundStyle(procSort == s ? Dark.text : Dark.dim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(procSort == s ? Color.white.opacity(0.09) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )

            Spacer()

            Text("悬停行尾出现 ✕ · 右键更多操作")
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    private var procHeader: some View {
        HStack(spacing: 8) {
            Text("进程").frame(maxWidth: .infinity, alignment: .leading)
            Text("PID").frame(width: ProcCol.pid, alignment: .trailing)
            Text("CPU").frame(width: ProcCol.cpu, alignment: .trailing)
            Text("内存").frame(width: ProcCol.mem, alignment: .trailing)
            Text("线程").frame(width: ProcCol.threads, alignment: .trailing)
            Text("用户").frame(width: ProcCol.user, alignment: .trailing)
            Text("").frame(width: ProcCol.kill)
        }
        .font(.system(size: 9))
        .foregroundStyle(Dark.faint)
        .padding(.horizontal, 11)
        .padding(.bottom, 5)
    }

    // MARK: 磁盘

    private var diskPage: some View {
        let rMax = max(store.diskRSeries.values(for: range).max() ?? 1, 1024)
        let wMax = max(store.diskWSeries.values(for: range).max() ?? 1, 1024)
        return VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("已用", Fmt.gbValue(store.disk.used), "/ \(Fmt.gb(store.disk.total))",
                       Dark.amber, spark: [], maxV: 1)
                kpiBox("可用", Fmt.gbValue(store.disk.free), "GB", Dark.green, spark: [], maxV: 1)
                kpiBox("使用率", "\(Int((store.disk.ratio * 100).rounded()))", "%",
                       store.disk.ratio > 0.9 ? Dark.red : Dark.blue, spark: [], maxV: 1)
                kpiBox("读取", Fmt.rate(store.disk.readBps).0, Fmt.rate(store.disk.readBps).1, Dark.blue,
                       spark: store.diskRSeries.values(for: .m1),
                       maxV: max(store.diskRSeries.values(for: .m1).max() ?? 1, 1024))
                kpiBox("写入", Fmt.rate(store.disk.writeBps).0, Fmt.rate(store.disk.writeBps).1, Dark.purple,
                       spark: store.diskWSeries.values(for: .m1),
                       maxV: max(store.diskWSeries.values(for: .m1).max() ?? 1, 1024))
            }
            .frame(height: 78)

            panelBox("磁盘读取", hint: "峰值 \(rateText(store.diskRSeries.values(for: range).max() ?? 0))") {
                ProChart(values: store.diskRSeries.values(for: range), minV: 0, maxV: rMax,
                         color: Dark.blue, format: rateFmt(rMax))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 11) {
                panelBox("容量", hint: "\(Int((store.disk.ratio * 100).rounded()))% 已使用") {
                    VStack(alignment: .leading, spacing: 9) {
                        GeometryReader { geo in
                            let w = geo.size.width
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(store.disk.ratio > 0.9 ? Dark.red : Dark.amber)
                                    .frame(width: max(4, w * CGFloat(store.disk.ratio) - 1))
                                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10))
                            }
                        }
                        .frame(height: 10)

                        HStack {
                            Text("已用 \(Fmt.gb(store.disk.used))").font(.system(size: 10)).foregroundStyle(Dark.dim)
                            Spacer()
                            Text("可用 \(Fmt.gb(store.disk.free))").font(.system(size: 10)).foregroundStyle(Dark.dim)
                        }

                        Rectangle().fill(Dark.border).frame(height: 0.5)

                        legendRow(Dark.dim, "文件系统", store.disk.fsType)
                        legendRow(Dark.dim, "总容量", Fmt.gb(store.disk.total))
                        legendRow(Dark.dim, "块大小", "\(store.disk.blockSize / 1024) KB")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
                panelBox("磁盘写入", hint: "峰值 \(rateText(store.diskWSeries.values(for: range).max() ?? 0))") {
                    ProChart(values: store.diskWSeries.values(for: range), minV: 0, maxV: wMax,
                             color: Dark.purple, format: rateFmt(wMax))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            .frame(height: 200)
        }
    }

    // MARK: 网络

    private var networkPage: some View {
        let dMax = max(store.netDownSeries.values(for: range).max() ?? 1, 1024)
        let uMax = max(store.netUpSeries.values(for: range).max() ?? 1, 1024)
        return VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("下行", Fmt.rate(store.network.down).0, Fmt.rate(store.network.down).1,
                       Dark.green, spark: store.netDownSeries.values(for: .m1),
                       maxV: max(store.netDownSeries.values(for: .m1).max() ?? 1, 1024))
                kpiBox("上行", Fmt.rate(store.network.up).0, Fmt.rate(store.network.up).1,
                       Dark.blue, spark: store.netUpSeries.values(for: .m1),
                       maxV: max(store.netUpSeries.values(for: .m1).max() ?? 1, 1024))
                kpiBox("累计下载", Fmt.size(store.network.totalDown), "", Dark.dim, spark: [], maxV: 1)
                kpiBox("累计上传", Fmt.size(store.network.totalUp), "", Dark.dim, spark: [], maxV: 1)
                kpiBox("接口", store.network.interfaceName.isEmpty ? "—" : store.network.interfaceName,
                       "", Dark.teal, spark: [], maxV: 1)
            }
            .frame(height: 78)

            panelBox("下载速率", hint: "峰值 \(rateText(store.netDownSeries.values(for: range).max() ?? 0))") {
                ProChart(values: store.netDownSeries.values(for: range), minV: 0, maxV: dMax,
                         color: Dark.green, format: rateFmt(dMax))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            panelBox("上传速率", hint: "峰值 \(rateText(store.netUpSeries.values(for: range).max() ?? 0))") {
                ProChart(values: store.netUpSeries.values(for: range), minV: 0, maxV: uMax,
                         color: Dark.blue, format: rateFmt(uMax))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: 传感器

    private var sensorPage: some View {
        VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("CPU 温度", store.sensor.cpuTemp > 0 ? String(format: "%.0f", store.sensor.cpuTemp) : "—",
                       "°C", tempColor, spark: store.tempSeries.values(for: .m1),
                       maxV: max((store.tempSeries.values(for: .m1).max() ?? 50) + 5, 60))
                kpiBox("GPU 温度", store.sensor.gpuTemp > 0 ? String(format: "%.0f", store.sensor.gpuTemp) : "—",
                       "°C", Dark.blue, spark: [], maxV: 1)
                kpiBox("GPU 利用率", store.gpu.available ? String(format: "%.0f", store.gpu.utilization) : "—",
                       "%", Dark.teal, spark: [], maxV: 1)
                kpiBox("显存", store.gpu.available ? Fmt.size(store.gpu.memUsed) : "—", "", Dark.purple, spark: [], maxV: 1)
                kpiBox("热压", store.sensor.thermalText, "", thermalColor, spark: [], maxV: 1)
            }
            .frame(height: 78)

            panelBox("CPU 温度", hint: "峰值 \(String(format: "%.1f", store.tempSeries.values(for: range).max() ?? 0))°C") {
                ProChart(values: store.tempSeries.values(for: range),
                         minV: max(0, (store.tempSeries.values(for: range).min() ?? 30) - 3),
                         maxV: max((store.tempSeries.values(for: range).max() ?? 50) + 5, 60),
                         color: Dark.amber) { String(format: "%.0f°", $0) }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 11) {
                panelBox("传感器明细", hint: nil) {
                    VStack(spacing: 0) {
                        legendRow(Dark.blue, "CPU die", store.sensor.cpuTemp > 0 ? String(format: "%.1f °C", store.sensor.cpuTemp) : "—")
                        legendRow(Dark.blue, "GPU die", store.sensor.gpuTemp > 0 ? String(format: "%.1f °C", store.sensor.gpuTemp) : "—")
                        legendRow(Dark.teal, "SOC", store.sensor.socTemp > 0 ? String(format: "%.1f °C", store.sensor.socTemp) : "—")
                        legendRow(Dark.purple, "SSD", store.sensor.ssdTemp > 0 ? String(format: "%.1f °C", store.sensor.ssdTemp) : "—")
                        legendRow(Dark.amber, "风扇", store.sensor.fanRPM >= 0 ? String(format: "%.0f rpm", store.sensor.fanRPM) : "系统未开放")
                        Rectangle().fill(Dark.border).frame(height: 0.5).padding(.vertical, 3)
                        legendRow(Dark.dim, "60 秒平均", String(format: "%.1f °C", avg(store.tempSeries.values(for: .m1))))
                        legendRow(Dark.dim, "60 秒峰值", String(format: "%.1f °C", store.tempSeries.values(for: .m1).max() ?? 0))
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
                panelBox("散热状态", hint: nil) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 7) {
                            Circle().fill(thermalColor).frame(width: 8, height: 8)
                            Text(store.sensor.thermalText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(thermalColor)
                            Spacer()
                            Text(store.sensor.cpuTemp > 0 ? String(format: "%.0f°C", store.sensor.cpuTemp) : "—")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(tempColor)
                        }

                        tempGauge

                        Text("风扇转速在 Apple Silicon 上需经 SMC 私有接口读取，本机该接口对所有键（含 #KEY）返回「键不存在」，且 IOHID 传感器列表里也没有风扇项，因此不显示。热压等级由 macOS 根据散热余量动态调整。")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Dark.faint)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Rectangle().fill(Dark.border).frame(height: 0.5)

                        HStack {
                            Text("距 90°C 警戒线").font(.system(size: 9.5)).foregroundStyle(Dark.dim)
                            Spacer()
                            Text(store.sensor.cpuTemp > 0
                                 ? String(format: "%.1f°C", max(0, 90 - store.sensor.cpuTemp))
                                 : "—")
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(store.sensor.cpuTemp >= 80 ? Dark.amber : Dark.green)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
            }
            .frame(height: 186)
        }
    }

    // MARK: 系统

    private var systemPage: some View {
        let info = store.sysInfo
        return VStack(spacing: 11) {
            HStack(spacing: 11) {
                kpiBox("芯片", info.chip, "", Dark.blue, spark: [], maxV: 1)
                kpiBox("内存", Fmt.gbValue(info.memoryBytes), "GB", Dark.purple, spark: [], maxV: 1)
                kpiBox("存储", Fmt.gbValue(store.disk.total), "GB", Dark.amber, spark: [], maxV: 1)
                kpiBox("核心", "\(info.totalCores)", "核", Dark.teal, spark: [], maxV: 1)
                kpiBox("已开机", info.uptimeText, "", Dark.green, spark: [], maxV: 1)
            }
            .frame(height: 78)

            HStack(spacing: 11) {
                panelBox("设备", hint: info.modelIdentifier) {
                    distributedKV([
                        (Dark.blue, "型号名称", info.modelName),
                        (Dark.dim, "型号标识", info.modelIdentifier),
                        (Dark.dim, "芯片", info.chip),
                        (Dark.teal, "核心构成", "\(info.totalCores) 核（\(info.pCores)P + \(info.eCores)E）"),
                        (Dark.purple, "统一内存", Fmt.gb(info.memoryBytes)),
                        (Dark.amber, "序列号", info.serial),
                        (Dark.dim, "架构", info.arch),
                        (Dark.dim, "系统盘", Fmt.gb(store.disk.total))
                    ])
                }
                panelBox("系统", hint: info.arch) {
                    distributedKV([
                        (Dark.blue, "系统版本", info.osVersion),
                        (Dark.dim, "构建号", info.osBuild),
                        (Dark.teal, "主机名", info.hostname),
                        (Dark.dim, "局域网 IP", info.localIP),
                        (Dark.dim, "开机时间", Self.dateFormatter.string(from: info.bootTime)),
                        (Dark.green, "已运行", info.uptimeText),
                        (Dark.amber, "物理分辨率", info.displayPixels),
                        (Dark.dim, "逻辑分辨率", info.displayPoints),
                        (Dark.dim, "缩放倍率", "\(info.displayScale)×")
                    ])
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 11) {
                panelBox("存储", hint: "\(Int((store.disk.ratio * 100).rounded()))% 已使用") {
                    VStack(alignment: .leading, spacing: 9) {
                        GeometryReader { geo in
                            let w = geo.size.width
                            HStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(store.disk.ratio > 0.9 ? Dark.red : Dark.amber)
                                    .frame(width: max(4, w * CGFloat(store.disk.ratio) - 1))
                                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10))
                            }
                        }
                        .frame(height: 9)

                        HStack {
                            Text("已用 \(Fmt.gb(store.disk.used))").font(.system(size: 10)).foregroundStyle(Dark.dim)
                            Spacer()
                            Text("可用 \(Fmt.gb(store.disk.free))").font(.system(size: 10)).foregroundStyle(Dark.dim)
                            Spacer()
                            Text("共 \(Fmt.gb(store.disk.total))").font(.system(size: 10)).foregroundStyle(Dark.dim)
                        }

                        Rectangle().fill(Dark.border).frame(height: 0.5)

                        legendRow(Dark.dim, "文件系统", store.disk.fsType)
                        Spacer(minLength: 0)
                        legendRow(Dark.blue, "读取", rateText(store.disk.readBps))
                        Spacer(minLength: 0)
                        legendRow(Dark.purple, "写入", rateText(store.disk.writeBps))
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 5)
                    .padding(.bottom, 10)
                }

                panelBox("电池", hint: store.battery.pluggedIn ? "已接电源" : "电池供电") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(store.battery.available ? "\(store.battery.percent)" : "—")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(store.battery.percent > 20 ? Dark.green : Dark.amber)
                            Text("%").font(.system(size: 10)).foregroundStyle(Dark.faint)
                            Spacer()
                            Text(store.battery.charging ? "充电中"
                                 : (store.battery.pluggedIn ? "已充满" : "放电中"))
                                .font(.system(size: 10))
                                .foregroundStyle(Dark.dim)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(store.battery.percent > 20 ? Dark.green : Dark.amber)
                                    .frame(width: max(4, geo.size.width * CGFloat(store.battery.percent) / 100))
                            }
                        }
                        .frame(height: 7)

                        legendRow(Dark.dim, "健康度", store.battery.health > 0
                                  ? "\(Int((store.battery.health * 100).rounded()))%" : "—")
                        Spacer(minLength: 0)
                        legendRow(Dark.dim, "循环次数", "\(store.battery.cycles) 次")
                        Spacer(minLength: 0)
                        legendRow(Dark.dim, "满充容量", "\(Int(store.battery.fullCapacity)) / \(Int(store.battery.designCapacity)) mAh")
                    }
                    .padding(.horizontal, 11)
                    .padding(.top, 5)
                    .padding(.bottom, 10)
                }
            }
            .frame(height: 252)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // MARK: 通用组件

    private func kpiBox(_ title: String, _ value: String, _ unit: String, _ color: Color,
                        spark: [Double], maxV: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Dark.faint)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Dark.faint)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            if spark.count > 1 {
                Sparkline(values: spark, maxValue: max(maxV, 0.0001), color: color.opacity(0.85))
                    .frame(height: 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Dark.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Dark.border, lineWidth: 0.5)
        )
    }

    private func panelBox<C: View>(_ title: String, hint: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Dark.text)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Dark.faint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            Rectangle().fill(Dark.border).frame(height: 0.5)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Dark.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Dark.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func processTable(limit: Int, byMemory: Bool) -> some View {
        let rows = byMemory
            ? store.processes.sorted { $0.mem > $1.mem }
            : store.processes.sorted { $0.cpu > $1.cpu }

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("进程").font(.system(size: 9)).foregroundStyle(Dark.faint)
                Spacer()
                Text("CPU").font(.system(size: 9)).foregroundStyle(Dark.faint).frame(width: 52, alignment: .trailing)
                Text("内存").font(.system(size: 9)).foregroundStyle(Dark.faint).frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 5)

            ForEach(Array(rows.prefix(limit).enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(Dark.faint)
                        .frame(width: 12, alignment: .trailing)
                    Text(p.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Dark.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f%%", p.cpu))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(p.cpu >= 30 ? Dark.red : (p.cpu >= 8 ? Dark.amber : Dark.dim))
                        .frame(width: 52, alignment: .trailing)
                    Text(Fmt.size(p.mem))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Dark.dim)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 4.5)
                .background(i % 2 == 1 ? Color.white.opacity(0.018) : Color.clear)
            }

            if rows.isEmpty {
                Text("采样中…").font(.system(size: 10)).foregroundStyle(Dark.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            Spacer(minLength: 0)
        }
    }

    /// 键值行均匀分布：行与行之间用弹性间隔撑开，把面板高度吃满
    @ViewBuilder
    private func distributedKV(_ rows: [(Color, String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                legendRow(r.0, r.1, r.2)
                Spacer(minLength: 2)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func miniRow(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Text(k).font(.system(size: 10)).foregroundStyle(Dark.dim)
            Spacer()
            Text(v).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(c)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Dark.border).frame(height: 0.5)
        }
    }

    // MARK: 工具

    private func avg(_ v: [Double]) -> Double {
        v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    /// 速率坐标轴：整条轴统一单位，避免出现 "2.0 / 1.5 / 523 / 0" 这种混单位刻度
    private func rateFmt(_ maxV: Double) -> (Double) -> String {
        if maxV >= 1_048_576 {
            return { String(format: "%.1f", $0 / 1_048_576) }
        }
        return { String(format: "%.0f", $0 / 1024) }
    }

    private func rateText(_ bps: Double) -> String {
        let r = Fmt.rate(bps)
        return "\(r.0) \(r.1)"
    }

    private var tempColor: Color {
        let t = store.sensor.cpuTemp
        if t >= 90 { return Dark.red }
        if t >= 75 { return Dark.amber }
        return Dark.blue
    }

    private var thermalColor: Color {
        switch store.sensor.thermalLevel {
        case 0: return Dark.green
        case 1: return Dark.amber
        default: return Dark.red
        }
    }

    private var pressureColor: Color {
        switch store.memory.pressure {
        case 1: return Dark.green
        case 2: return Dark.amber
        default: return Dark.red
        }
    }
}

// MARK: - 每核柱状图（窗口用）
//
// 热力色块看不出高低，改成真正的柱状：底色是轨道，彩色柱高 = 占用率。

struct CoreBars: View {
    let cores: [Double]
    let pCount: Int

    var body: some View {
        let eCount = max(0, cores.count - min(pCount, cores.count))
        GeometryReader { geo in
            let h = max(24, geo.size.height - 28)
            HStack(spacing: 5) {
                ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                    let isP = i >= eCount
                    let base = isP ? Dark.blue : Dark.teal
                    VStack(spacing: 3) {
                        Text("\(Int(v.rounded()))")
                            .font(.system(size: 8.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(isP ? Dark.blue : Dark.teal)

                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.045))
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(
                                    LinearGradient(colors: [base.opacity(0.95), base.opacity(0.55)],
                                                   startPoint: .bottom, endPoint: .top)
                                )
                                .frame(height: max(2, h * min(1, v / 100)))
                        }
                        .frame(height: h)

                        Text(isP ? "P\(i - eCount + 1)" : "E\(i + 1)")
                            .font(.system(size: 7.5))
                            .foregroundStyle(Dark.faint)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - 专业图表（带网格与刻度）

struct ProChart: View {
    var values: [Double]
    var minV: Double
    var maxV: Double
    var color: Color
    var format: (Double) -> String

    private let axisW: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let plotW = max(0, geo.size.width - axisW)
            let plotH = geo.size.height - 16
            let pts = points(plotW: plotW, plotH: plotH)

            ZStack(alignment: .topLeading) {
                // 横向网格 + 右侧刻度
                ForEach(0..<5, id: \.self) { i in
                    let frac = CGFloat(i) / 4
                    let y = plotH * frac
                    Rectangle()
                        .fill(Color.white.opacity(i == 4 ? 0.10 : 0.045))
                        .frame(width: plotW, height: 0.5)
                        .offset(y: y)

                    Text(format(maxV - (maxV - minV) * Double(frac)))
                        .font(.system(size: 8))
                        .monospacedDigit()
                        .foregroundStyle(Dark.faint)
                        .frame(width: axisW - 6, alignment: .trailing)
                        .offset(x: plotW + 6, y: y - 5)
                }

                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: plotH))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: plotH))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(colors: [color.opacity(0.28), color.opacity(0.01)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                } else {
                    Text("等待数据…")
                        .font(.system(size: 10))
                        .foregroundStyle(Dark.faint)
                        .frame(width: plotW, height: plotH)
                }
            }
        }
    }

    private func points(plotW: CGFloat, plotH: CGFloat) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = plotW / CGFloat(values.count - 1)
        let span = max(maxV - minV, 0.0001)
        return values.enumerated().map { i, v in
            let r = min(1, max(0, (v - minV) / span))
            return CGPoint(x: CGFloat(i) * step, y: plotH - CGFloat(r) * (plotH - 4) - 2)
        }
    }
}

// MARK: - 进程列表列宽
//
// 表头和数据行共用同一组常量，否则改一处就错位。

private enum ProcCol {
    static let pid: CGFloat = 56
    static let cpu: CGFloat = 58
    static let mem: CGFloat = 66
    static let threads: CGFloat = 42
    static let user: CGFloat = 74
    static let kill: CGFloat = 18
}

// MARK: - 进程行
//
// 单击 → 详情；右键 → 结束 / 定位 / 复制；悬停行尾浮出 ✕ 直接结束。
// ✕ 常驻占位（平时透明），避免悬停时整行宽度跳动。

private struct ProcessRowView: View {
    let p: ProcSample
    let index: Int
    var onKill: (Bool) -> Void
    var onDetail: () -> Void

    @State private var hover = false

    private var blocked: String? { ProcessActions.blockedReason(p) }

    var body: some View {
        HStack(spacing: 8) {
            Text(p.name)
                .font(.system(size: 10.5))
                .foregroundStyle(p.isSystem ? Dark.dim : Dark.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(p.pid)")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Dark.faint)
                .frame(width: ProcCol.pid, alignment: .trailing)

            Text(p.hasMetrics ? String(format: "%.1f%%", p.cpu) : "—")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(!p.hasMetrics ? Dark.faint
                                 : (p.cpu >= 30 ? Dark.red : (p.cpu >= 8 ? Dark.amber : Dark.dim)))
                .frame(width: ProcCol.cpu, alignment: .trailing)

            Text(p.hasMetrics ? Fmt.size(p.mem) : "—")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Dark.dim)
                .frame(width: ProcCol.mem, alignment: .trailing)

            Text(p.hasMetrics ? "\(p.threads)" : "—")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Dark.faint)
                .frame(width: ProcCol.threads, alignment: .trailing)

            Text(p.user)
                .font(.system(size: 9.5))
                .foregroundStyle(Dark.faint)
                .lineLimit(1)
                .frame(width: ProcCol.user, alignment: .trailing)

            Button { onKill(false) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(hover && blocked == nil
                                     ? Dark.red.opacity(0.9)
                                     : Color.clear)
            }
            .buttonStyle(.plain)
            .frame(width: ProcCol.kill)
            .disabled(blocked != nil)
            .help(blocked ?? "结束进程")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 3.5)
        .background(
            Rectangle().fill(hover ? Color.white.opacity(0.055)
                                   : (index % 2 == 1 ? Color.white.opacity(0.018) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onDetail() }
        .help(p.path.isEmpty ? "PID \(p.pid)" : p.path)
        .contextMenu {
            if let blocked {
                Text(blocked)
                Divider()
            }
            Button("结束进程") { onKill(false) }
                .disabled(blocked != nil)
            Button("强制结束") { onKill(true) }
                .disabled(blocked != nil)
            Divider()
            Button("查看详情") { onDetail() }
            Button("在 Finder 中显示") { ProcessActions.reveal(p) }
            Divider()
            Button("复制进程名") { ProcessActions.copy(p.name) }
            Button("复制 PID") { ProcessActions.copy("\(p.pid)") }
            Button("复制路径") { ProcessActions.copy(p.path) }
            Divider()
            Button("打开活动监视器") { ProcessActions.openActivityMonitor() }
        }
    }
}

// MARK: - 进程详情

private struct ProcessDetailSheet: View {
    let detail: ProcessDetail
    var onKill: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private var blocked: String? {
        ProcessActions.blockedReason(
            ProcSample(pid: detail.pid, name: detail.name, cpu: detail.cpu, mem: detail.mem)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Dark.border).frame(height: 0.5)

            VStack(spacing: 0) {
                kvRow("用户", detail.user + (detail.isSystem ? " · 系统进程" : ""))
                kvRow("PID", "\(detail.pid)　父进程 \(detail.ppid)")
                kvRow("状态", detail.status)
                kvRow("线程", "\(detail.threads)")
                kvRow("CPU", String(format: "%.1f%%", detail.cpu),
                      color: detail.cpu >= 30 ? Dark.red : Dark.text)
                kvRow("内存", Fmt.size(detail.mem))
                kvRow("启动", detail.start.map { Self.timeFormatter.string(from: $0) } ?? "—")
                kvRow("运行", detail.uptimeText)
                kvRow("路径", detail.path.isEmpty ? "—" : detail.path)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Rectangle().fill(Dark.border).frame(height: 0.5)
            footer
        }
        .frame(width: 470)
        .background(Dark.panel)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(detail.isSystem ? Dark.amber.opacity(0.14) : Dark.blue.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: detail.isSystem ? "gearshape.fill" : "app.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(detail.isSystem ? Dark.amber : Dark.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(detail.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Dark.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("PID \(detail.pid) · \(detail.user)")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(Dark.faint)
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Dark.dim)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let blocked {
                Text(blocked)
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.amber)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            Button {
                ProcessActions.copy(detail.path)
            } label: {
                Text("复制路径")
                    .font(.system(size: 10))
                    .foregroundStyle(Dark.dim)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)

            Button {
                onKill(true)
                dismiss()
            } label: {
                Text("强制结束")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(blocked == nil ? Dark.red : Dark.faint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Dark.red.opacity(blocked == nil ? 0.14 : 0.05))
                    )
            }
            .buttonStyle(.plain)
            .disabled(blocked != nil)

            Button {
                onKill(false)
                dismiss()
            } label: {
                Text("结束进程")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(blocked == nil ? Color.white : Dark.faint)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(blocked == nil ? Dark.blue : Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .disabled(blocked != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func kvRow(_ k: String, _ v: String, color: Color = Dark.text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k)
                .font(.system(size: 9.5))
                .foregroundStyle(Dark.faint)
                .frame(width: 34, alignment: .leading)
            Text(v)
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3.5)
    }
}
