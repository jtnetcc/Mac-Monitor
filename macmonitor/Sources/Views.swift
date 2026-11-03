import SwiftUI

// MARK: - 主题

enum Theme {
    static let accent = Color(red: 0.00, green: 0.478, blue: 1.00)
    static let ok     = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warn   = Color(red: 1.00, green: 0.58, blue: 0.00)
    static let danger = Color(red: 1.00, green: 0.23, blue: 0.19)
    /// E 核用青色，和 P 核的蓝色区分开
    static let teal   = Color(red: 0.11, green: 0.62, blue: 0.46)

    static func loadColor(_ v: Double) -> Color {
        if v >= 90 { return danger }
        if v >= 70 { return warn }
        return accent
    }
}

extension View {
    /// 让整块区域可点击 + 悬停变手型光标
    func clickable(_ action: @escaping () -> Void) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { inside in
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }
}

// MARK: - 迷你折线（窗口与面板共用）

struct Sparkline: View {
    var values: [Double]
    var maxValue: Double
    var color: Color
    /// 底部基线：让贴着某一段的平线读起来是「稳定在 75%」而不是「一条孤线」
    var showBaseline: Bool = false

    var body: some View {
        GeometryReader { geo in
            let pts = normalize(values, in: geo.size, maxV: maxValue)
            ZStack(alignment: .bottom) {
                if showBaseline {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func normalize(_ v: [Double], in size: CGSize, maxV: Double) -> [CGPoint] {
        guard v.count > 1 else { return [] }
        let step = size.width / CGFloat(v.count - 1)
        return v.enumerated().map { i, val in
            let r = min(1, max(0, val / max(maxV, 0.0001)))
            return CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(r) * size.height)
        }
    }
}

// MARK: - 操作反馈提示条（面板与详情窗口共用）

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(toast.ok ? Dark.green : Dark.amber)
            Text(toast.text)
                .font(.system(size: 10.5))
                .foregroundStyle(Dark.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: 0x23272F))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }
}

// MARK: - 图表页签

enum ChartTab: String, CaseIterable {
    case cpu = "CPU", mem = "内存", net = "网络", disk = "磁盘", temp = "温度"
}

// MARK: - 精简面板
//
// 设计目标：和详情窗口同一套深色语言。去掉层层嵌套的圆角卡片，
// 改用分隔线 + 留白建立层次。信息量不减，视觉噪音大幅下降。

struct DashboardView: View {
    @ObservedObject var store: MetricsStore
    /// 调试用：强制选中某个页签（ImageRenderer 无法模拟点击）
    var forceTab: ChartTab? = nil
    /// 点击指标 → 打开详情窗口对应分区
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    @State private var range: TimeRange = .m1

    private var tab: ChartTab { forceTab ?? tabState }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let alert = store.alert {
                alertBanner(alert).padding(.top, 8)
            }
            kpiRow.padding(.top, 10)
            hairline.padding(.vertical, 10)
            tabStrip
            chart.padding(.top, 7)
            ioRow.padding(.top, 9)
            hairline.padding(.vertical, 10)
            processSection
            footer.padding(.top, 9)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: 342)
        .background(Dark.panel)
        .overlay(alignment: .bottom) {
            ZStack {
                if let t = store.toast {
                    ToastView(toast: t)
                        .id(t.id)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: store.toast?.id)
        }
    }

    // MARK: 告警条

    private func alertBanner(_ a: AlertEvent) -> some View {
        let c = a.level == .danger ? Dark.red : Dark.amber
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(c)
                .frame(width: 2.5, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(a.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(c)
                Text(a.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)

            Button {
                store.dismissAlert()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Dark.dim)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(c.opacity(0.11))
        )
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Dark.blue)
                .frame(width: 6, height: 6)
                .shadow(color: Dark.blue.opacity(0.6), radius: 3)

            Text("Mac Monitor")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Dark.text)

            Spacer()

            Button {
                onOpen(.overview)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 9, weight: .medium))
                    Text("详情")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(Dark.blue)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Dark.blue.opacity(0.13))
                )
            }
            .buttonStyle(.plain)
            .help("打开详情窗口")

            Text(store.chipName)
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
        }
    }

    // MARK: KPI 行

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 0) {
            kpiCell("CPU", "\(Int(store.cpu.total.rounded()))", "%",
                    Dark.load(store.cpu.total),
                    spark: store.cpuSeries.values(for: .m1), maxV: 100,
                    action: { onOpen(.cpu) })

            vSep

            kpiCell("内存", Fmt.gbValue(store.memory.used), "GB",
                    Dark.purple,
                    spark: store.memSeries.values(for: .m1), maxV: 100,
                    action: { onOpen(.memory) })

            vSep

            kpiCell("温度", store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—", "°C",
                    tempColor,
                    spark: store.tempSeries.values(for: .m1),
                    maxV: max((store.tempSeries.values(for: .m1).max() ?? 50) + 5, 60),
                    action: { onOpen(.sensor) })
        }
    }

    private var vSep: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 0.5, height: 42)
            .padding(.horizontal, 10)
    }

    private func kpiCell(_ title: String, _ value: String, _ unit: String,
                         _ color: Color, spark: [Double], maxV: Double,
                         action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(Dark.faint)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.faint)
            }
            .padding(.top, 1)

            if spark.count > 1 {
                Sparkline(values: spark, maxValue: max(maxV, 0.0001),
                          color: color.opacity(0.85), showBaseline: true)
                    .frame(height: 11)
                    .padding(.top, 3)
            } else {
                Spacer().frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clickable(action)
    }

    // MARK: 页签

    private var tabStrip: some View {
        HStack(spacing: 1) {
            ForEach(ChartTab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { tabState = t }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 10, weight: tab == t ? .medium : .regular))
                        .foregroundStyle(tab == t ? Dark.text : Dark.dim)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(tab == t ? Color.white.opacity(0.09) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(range.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
        }
    }

    // MARK: 图表

    private var chartData: (values: [Double], minV: Double, maxV: Double, color: Color) {
        switch tab {
        case .cpu:
            return (store.cpuSeries.values(for: range), 0, 100, Dark.blue)
        case .mem:
            return (store.memSeries.values(for: range), 0, 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: range)
            return (v, 0, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: range)
            return (v, 0, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: range)
            let lo = max(0, (v.min() ?? 30) - 3)
            return (v, lo, max((v.max() ?? 50) + 5, lo + 10), Dark.amber)
        }
    }

    private var chart: some View {
        ProChart(values: chartData.values,
                 minV: chartData.minV,
                 maxV: chartData.maxV,
                 color: chartData.color,
                 format: chartFormat)
            .frame(height: 74)
    }

    private var chartFormat: (Double) -> String {
        switch tab {
        case .cpu, .mem:
            return { "\(Int($0))%" }
        case .net, .disk:
            let m = chartData.maxV
            if m >= 1_048_576 { return { String(format: "%.1f", $0 / 1_048_576) } }
            return { String(format: "%.0f", $0 / 1024) }
        case .temp:
            return { String(format: "%.0f°", $0) }
        }
    }

    // MARK: 网络 / 磁盘

    private var ioRow: some View {
        HStack(spacing: 0) {
            ioCell("网络", [
                ("↓", Fmt.rate(store.network.down), Dark.green),
                ("↑", Fmt.rate(store.network.up), Dark.blue)
            ], action: { onOpen(.network) })

            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.5, height: 24)
                .padding(.horizontal, 9)

            ioCell("磁盘", [
                ("读", Fmt.rate(store.disk.readBps), Dark.amber),
                ("写", Fmt.rate(store.disk.writeBps), Dark.purple)
            ], action: { onOpen(.disk) })
        }
    }

    private func ioCell(_ title: String,
                        _ items: [(String, (String, String), Color)],
                        action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 2) {
                    Text(item.0).font(.system(size: 9)).foregroundStyle(item.2.opacity(0.85))
                    Text(item.1.0)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Dark.text)
                    Text(item.1.1)
                        .font(.system(size: 8))
                        .foregroundStyle(Dark.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clickable(action)
    }

    // MARK: 进程

    private var processSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("进程")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(Dark.faint)
                Spacer()
                Text("按 CPU · 右键结束")
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.faint)
            }
            .padding(.bottom, 6)

            ForEach(Array(store.processes.prefix(4).enumerated()), id: \.element.id) { i, p in
                PanelProcRow(p: p, index: i) { force in
                    store.terminate(p, force: force)
                }
            }

            if store.processes.isEmpty {
                Text("采样中…")
                    .font(.system(size: 10))
                    .foregroundStyle(Dark.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: 底部状态

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Circle()
                    .fill(store.battery.charging ? Dark.green : Dark.faint)
                    .frame(width: 5, height: 5)
                Text("电池 \(store.battery.available ? "\(store.battery.percent)%" : "—")")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Dark.dim)
                Text(store.battery.charging ? "充电中" : (store.battery.pluggedIn ? "接电源" : "放电"))
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.faint)
            }
            .clickable { onOpen(.sensor) }

            Spacer()

            Text("热压 \(store.sensor.thermalText)")
                .font(.system(size: 9))
                .foregroundStyle(thermalColor)

            Text("·")
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
                .padding(.horizontal, 5)

            Text("GPU \(store.gpu.available ? String(format: "%.0f%%", store.gpu.utilization) : "—")")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(Dark.faint)
        }
    }

    // MARK: 工具

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
}

// MARK: - 面板进程行
//
// 悬停时右侧浮出 ✕ 直接结束；右键是完整菜单。
// ✕ 常驻占位（透明），避免悬停时整行宽度跳动。

struct PanelProcRow: View {
    let p: ProcSample
    let index: Int
    var onKill: (Bool) -> Void
    /// 精简面板的新样式用，行高压一点、字号小半号
    var dense: Bool = false

    @State private var hover = false

    private var blocked: String? { ProcessActions.blockedReason(p) }

    var body: some View {
        HStack(spacing: 6) {
            Text(p.name)
                .font(.system(size: dense ? 10 : 10.5))
                .foregroundStyle(Dark.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(p.hasMetrics ? String(format: "%.1f%%", p.cpu) : "—")
                .font(.system(size: dense ? 9.5 : 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(!p.hasMetrics ? Dark.faint
                                 : (p.cpu >= 30 ? Dark.red : (p.cpu >= 8 ? Dark.amber : Dark.dim)))
                .frame(width: 44, alignment: .trailing)

            Text(p.hasMetrics ? Fmt.size(p.mem) : "—")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(Dark.faint)
                .frame(width: 50, alignment: .trailing)

            Button {
                onKill(false)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(hover && blocked == nil
                                     ? Dark.red.opacity(0.9)
                                     : Color.clear)
            }
            .buttonStyle(.plain)
            .frame(width: 11)
            .disabled(blocked != nil)
            .help(blocked ?? "结束进程")
        }
        .padding(.vertical, dense ? 2.5 : 3.5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hover ? Color.white.opacity(0.05)
                            : (index % 2 == 1 ? Color.white.opacity(0.015) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
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
            Button("在 Finder 中显示") { ProcessActions.reveal(p) }
            Button("复制进程名") { ProcessActions.copy(p.name) }
            Button("复制 PID") { ProcessActions.copy("\(p.pid)") }
            Divider()
            Button("打开活动监视器") { ProcessActions.openActivityMonitor() }
        }
    }
}
