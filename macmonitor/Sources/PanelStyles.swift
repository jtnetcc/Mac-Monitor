import SwiftUI

// MARK: - 精简面板的备选样式
//
// 现有样式（`DashboardView`）原样保留，这里只加新方案，用 `--panel-style` 切换预览。
// 三个方案共用同一批数据和小部件，差别在排版语言：
//
//   cards  控制中心风：内容分组进圆角卡片，指标卡并排
//   rings  仪表风：三个圆环 + 大图，和菜单栏那个圆环同一套语言
//   rows   列表风：单列条形，信息密度最高，几乎没有装饰
//
// 共同点：都去掉了图表右侧的刻度轴（44pt 宽在 342 的面板里太奢侈），
// 改成卡片内右上角一个「峰值」小字。

enum PanelStyle: String, CaseIterable {
    case current, cards, rings, rows, hero, dual, editorial

    var label: String {
        switch self {
        case .current: return "现有"
        case .cards:   return "卡片"
        case .rings:   return "圆环"
        case .rows:    return "列表"
        case .hero:    return "大图"
        case .dual:    return "双环"
        case .editorial: return "排版"
        }
    }
}

// MARK: - 共用小部件

/// 无刻度轴的迷你曲线：面积渐变 + 折线
struct PanelMiniChart: View {
    var values: [Double]
    var maxV: Double
    var color: Color
    var lineWidth: CGFloat = 1.6
    /// 按峰值自适应铺满。指标绝对值低的时候（比如 CPU 20%），
    /// 固定 0–100 的刻度会让曲线贴着底边，上面空一大片
    var fitToPeak: Bool = false

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth,
                                                      lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0, size.height > 0 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        let peak = values.max() ?? 0
        let top = fitToPeak ? max(peak * 1.18, maxV * 0.06, 0.0001) : max(maxV, 0.0001)
        return values.enumerated().map { i, v in
            let r = min(1, max(0, v / top))
            return CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(r) * size.height)
        }
    }
}

/// 圆环（和菜单栏图标同一个隐喻）
struct PanelRing: View {
    var percent: Double
    var color: Color
    var size: CGFloat = 54
    var width: CGFloat = 5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.075), lineWidth: width)
            Circle()
                .trim(from: 0, to: min(1, max(0, percent / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// 细横条（列表风的进度指示）
struct PanelBar: View {
    var percent: Double
    var color: Color
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, percent)) / 100)))
            }
        }
        .frame(height: height)
    }
}

/// 卡片底：圆角 + 极淡填充 + 1px 描边
private struct PanelCard<Content: View>: View {
    var padding: CGFloat = 9
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.038))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.5)
            )
    }
}

/// 顶部：状态点 + 标题 + 详情按钮 + 芯片
private struct PanelHeader: View {
    var chip: String
    var onOpen: (Section) -> Void

    /// 和 SoundAlert 共用同一个 UserDefaults key。
    /// 用 @AppStorage 而不是 @State：从右键菜单改了开关，面板这里也能立刻跟上
    @AppStorage("soundAlertEnabled") private var soundOn = true

    var body: some View {
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
                soundOn.toggle()
                if soundOn { SoundAlert.preview() }
            } label: {
                Image(systemName: soundOn ? "speaker.wave.1.fill" : "speaker.slash.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(soundOn ? Dark.dim : Dark.faint)
                    .frame(width: 17, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(soundOn ? 0.055 : 0.02))
                    )
            }
            .buttonStyle(.plain)
            .help(soundOn ? "关闭告警提示音" : "打开告警提示音")
            Button { onOpen(.overview) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "macwindow").font(.system(size: 9, weight: .medium))
                    Text("详情").font(.system(size: 9.5, weight: .medium))
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
            Text(chip)
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
        }
    }
}

/// 底部：电池 / 热压 / GPU
private struct PanelFooter: View {
    @ObservedObject var store: MetricsStore
    var onOpen: (Section) -> Void

    private var thermalColor: Color {
        switch store.sensor.thermalLevel {
        case 0: return Dark.green
        case 1: return Dark.amber
        default: return Dark.red
        }
    }

    var body: some View {
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
}

/// 进程前 4 行（和现有样式同一套行组件，交互一致）
private struct PanelProcessList: View {
    @ObservedObject var store: MetricsStore
    var compact: Bool = false
    var limit: Int = 4

    var body: some View {
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
            .padding(.bottom, compact ? 4 : 6)

            ForEach(Array(store.processes.prefix(limit).enumerated()), id: \.element.id) { i, p in
                PanelProcRow(p: p, index: i,
                             onKill: { force in store.terminate(p, force: force) },
                             dense: compact)
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
}

/// 页签条，两种密度
private struct PanelTabs: View {
    @Binding var tab: ChartTab
    var range: TimeRange
    var dense: Bool = false

    var body: some View {
        HStack(spacing: dense ? 0 : 1) {
            ForEach(ChartTab.allCases, id: \.self) { t in
                Button { withAnimation(.easeOut(duration: 0.12)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: dense ? 9.5 : 10,
                                      weight: tab == t ? .medium : .regular))
                        .foregroundStyle(tab == t ? Dark.text : Dark.dim)
                        .padding(.horizontal, dense ? 5.5 : 6.5)
                        .padding(.vertical, 2.5)
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
}

// MARK: - 方案 B：卡片

struct PanelCardsView: View {
    @ObservedObject var store: MetricsStore
    var forceTab: ChartTab? = nil
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    private var tab: ChartTab { forceTab ?? tabState }

    private var tempColor: Color {
        let t = store.sensor.cpuTemp
        if t >= 90 { return Dark.red }
        if t >= 75 { return Dark.amber }
        return Dark.blue
    }

    private var chart: (values: [Double], maxV: Double, color: Color) {
        switch tab {
        case .cpu:  return (store.cpuSeries.values(for: .m1), 100, Dark.blue)
        case .mem:  return (store.memSeries.values(for: .m1), 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: .m1)
            return (v, max((v.max() ?? 50) + 5, 60), Dark.amber)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            PanelHeader(chip: store.chipName, onOpen: onOpen)
            if let alert = store.alert {
                PanelAlertBanner(alert: alert) { store.dismissAlert() }
                    .padding(.top, 8)
            }

            HStack(spacing: 6) {
                kpiCard("CPU", "\(Int(store.cpu.total.rounded()))", "%",
                        Dark.load(store.cpu.total),
                        store.cpuSeries.values(for: .m1), 100) { onOpen(.cpu) }
                kpiCard("内存", Fmt.gbValue(store.memory.used), "GB", Dark.purple,
                        store.memSeries.values(for: .m1), 100) { onOpen(.memory) }
                kpiCard("温度",
                        store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—",
                        "°C", tempColor,
                        store.tempSeries.values(for: .m1),
                        max((store.tempSeries.values(for: .m1).max() ?? 50) + 5, 60)) { onOpen(.sensor) }
            }

            PanelCard(padding: 8) {
                VStack(spacing: 6) {
                    PanelTabs(tab: Binding(get: { tab }, set: { tabState = $0 }), range: .m1, dense: true)
                    PanelMiniChart(values: chart.values, maxV: chart.maxV, color: chart.color)
                        .frame(height: 62)
                }
            }

            PanelCard(padding: 8) {
                HStack(spacing: 0) {
                    ioBlock("网络", [
                        ("↓", Fmt.rate(store.network.down), Dark.green),
                        ("↑", Fmt.rate(store.network.up), Dark.blue)
                    ]) { onOpen(.network) }
                    Rectangle().fill(Color.white.opacity(0.07))
                        .frame(width: 0.5, height: 26).padding(.horizontal, 10)
                    ioBlock("磁盘", [
                        ("读", Fmt.rate(store.disk.readBps), Dark.amber),
                        ("写", Fmt.rate(store.disk.writeBps), Dark.purple)
                    ]) { onOpen(.disk) }
                }
            }

            PanelProcessList(store: store, compact: true)
            Spacer(minLength: 0)
            PanelFooter(store: store, onOpen: onOpen)
                .padding(.top, 8)
                .padding(.top, 8)
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(width: 342)
        .background(Dark.panel)
    }

    private func kpiCard(_ title: String, _ value: String, _ unit: String, _ color: Color,
                         _ spark: [Double], _ maxV: Double,
                         action: @escaping () -> Void) -> some View {
        PanelCard(padding: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 8.5, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(Dark.faint)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Dark.faint)
                }
                if spark.count > 1 {
                    PanelMiniChart(values: spark, maxV: maxV, color: color, lineWidth: 1.3)
                        .frame(height: 12)
                        .opacity(0.9)
                } else {
                    Spacer().frame(height: 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clickable(action)
    }

    private func ioBlock(_ title: String,
                         _ items: [(String, (String, String), Color)],
                         action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8.5)).foregroundStyle(Dark.faint)
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 2) {
                        Text(item.0).font(.system(size: 9)).foregroundStyle(item.2.opacity(0.85))
                        Text(item.1.0)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Dark.text)
                        Text(item.1.1).font(.system(size: 8)).foregroundStyle(Dark.faint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clickable(action)
    }
}

// MARK: - 方案 C：圆环

struct PanelRingsView: View {
    @ObservedObject var store: MetricsStore
    var forceTab: ChartTab? = nil
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    private var tab: ChartTab { forceTab ?? tabState }

    private var tempColor: Color {
        let t = store.sensor.cpuTemp
        if t >= 90 { return Dark.red }
        if t >= 75 { return Dark.amber }
        return Dark.blue
    }

    private var chart: (values: [Double], maxV: Double, color: Color) {
        switch tab {
        case .cpu:  return (store.cpuSeries.values(for: .m1), 100, Dark.blue)
        case .mem:  return (store.memSeries.values(for: .m1), 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: .m1)
            return (v, max((v.max() ?? 50) + 5, 60), Dark.amber)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(chip: store.chipName, onOpen: onOpen)
            if let alert = store.alert {
                PanelAlertBanner(alert: alert) { store.dismissAlert() }
                    .padding(.top, 8)
            }

            HStack(spacing: 0) {
                ringCell("CPU", "\(Int(store.cpu.total.rounded()))", "%",
                         store.cpu.total, Dark.load(store.cpu.total)) { onOpen(.cpu) }
                ringCell("内存", Fmt.gbValue(store.memory.used), "GB",
                         store.memory.ratio * 100, Dark.purple) { onOpen(.memory) }
                ringCell("温度",
                         store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—",
                         "°C",
                         min(100, max(0, (store.sensor.cpuTemp - 30) / 70 * 100)),
                         tempColor) { onOpen(.sensor) }
            }
            .padding(.top, 12)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 10)

            PanelTabs(tab: Binding(get: { tab }, set: { tabState = $0 }), range: .m1)
            PanelMiniChart(values: chart.values, maxV: chart.maxV, color: chart.color)
                .frame(height: 74)
                .padding(.top, 7)

            HStack(spacing: 0) {
                ioInline("网络", [("↓", Fmt.rate(store.network.down), Dark.green),
                                  ("↑", Fmt.rate(store.network.up), Dark.blue)]) { onOpen(.network) }
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.5, height: 22)
                    .padding(.horizontal, 9)
                ioInline("磁盘", [("读", Fmt.rate(store.disk.readBps), Dark.amber),
                                  ("写", Fmt.rate(store.disk.writeBps), Dark.purple)]) { onOpen(.disk) }
            }
            .padding(.top, 10)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 10)

            PanelProcessList(store: store)
            Spacer(minLength: 0)
            PanelFooter(store: store, onOpen: onOpen)
                .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(width: 342)
        .background(Dark.panel)
    }

    private func ringCell(_ title: String, _ value: String, _ unit: String,
                          _ percent: Double, _ color: Color,
                          action: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            ZStack {
                PanelRing(percent: percent, color: color)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Dark.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit)
                        .font(.system(size: 7.5))
                        .foregroundStyle(Dark.faint)
                }
                .padding(.horizontal, 6)
            }
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
        }
        .frame(maxWidth: .infinity)
        .clickable(action)
    }

    private func ioInline(_ title: String,
                          _ items: [(String, (String, String), Color)],
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 9)).foregroundStyle(Dark.faint)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 2) {
                    Text(item.0).font(.system(size: 9)).foregroundStyle(item.2.opacity(0.85))
                    Text(item.1.0)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Dark.text)
                    Text(item.1.1).font(.system(size: 8)).foregroundStyle(Dark.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clickable(action)
    }
}

// MARK: - 方案 D：单列

struct PanelRowsView: View {
    @ObservedObject var store: MetricsStore
    var forceTab: ChartTab? = nil
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    private var tab: ChartTab { forceTab ?? tabState }

    private var tempColor: Color {
        let t = store.sensor.cpuTemp
        if t >= 90 { return Dark.red }
        if t >= 75 { return Dark.amber }
        return Dark.blue
    }

    private var chart: (values: [Double], maxV: Double, color: Color) {
        switch tab {
        case .cpu:  return (store.cpuSeries.values(for: .m1), 100, Dark.blue)
        case .mem:  return (store.memSeries.values(for: .m1), 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: .m1)
            return (v, max((v.max() ?? 50) + 5, 60), Dark.amber)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(chip: store.chipName, onOpen: onOpen)
                .padding(.bottom, 10)
            if let alert = store.alert {
                PanelAlertBanner(alert: alert) { store.dismissAlert() }
                    .padding(.bottom, 8)
            }

            VStack(spacing: 7) {
                row("CPU", "\(Int(store.cpu.total.rounded()))%",
                    store.cpu.total, Dark.load(store.cpu.total),
                    detail: "P \(Int(store.cpu.pAvg))% · E \(Int(store.cpu.eAvg))%") { onOpen(.cpu) }
                row("内存", "\(Fmt.gbValue(store.memory.used)) GB",
                    store.memory.ratio * 100, Dark.purple,
                    detail: store.memory.pressureText) { onOpen(.memory) }
                row("温度",
                    store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))°C" : "—",
                    min(100, max(0, (store.sensor.cpuTemp - 30) / 70 * 100)), tempColor,
                    detail: store.sensor.thermalText) { onOpen(.sensor) }
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 9)

            PanelTabs(tab: Binding(get: { tab }, set: { tabState = $0 }), range: .m1, dense: true)
            PanelMiniChart(values: chart.values, maxV: chart.maxV, color: chart.color,
                           lineWidth: 1.4)
                .frame(height: 52)
                .padding(.top, 6)

            HStack(spacing: 0) {
                Text("网络 ↓\(rate(store.network.down)) ↑\(rate(store.network.up))")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Dark.dim)
                    .clickable { onOpen(.network) }
                Spacer()
                Text("磁盘 读\(rate(store.disk.readBps)) 写\(rate(store.disk.writeBps))")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(Dark.dim)
                    .clickable { onOpen(.disk) }
            }
            .padding(.top, 9)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 9)

            PanelProcessList(store: store, compact: true)
            Spacer(minLength: 0)
            PanelFooter(store: store, onOpen: onOpen)
                .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .frame(width: 342)
        .background(Dark.panel)
    }

    private func rate(_ bps: Double) -> String {
        let r = Fmt.rate(bps)
        return "\(r.0) \(r.1)"
    }

    private func row(_ title: String, _ value: String, _ percent: Double, _ color: Color,
                     detail: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Dark.faint)
                    .frame(width: 34, alignment: .leading)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Spacer()
                Text(detail)
                    .font(.system(size: 8.5))
                    .monospacedDigit()
                    .foregroundStyle(Dark.faint)
            }
            PanelBar(percent: percent, color: color)
        }
        .clickable(action)
    }
}

// MARK: - 方案 E：大图（页签驱动的巨字 + 大曲线）
//
// 前几版都是「三栏 KPI + 图表 + 列表」，信息被切成三块一样重的区域，
// 谁都不突出。这一版把主导权交给当前页签：上面一个大数字，下面一张大曲线，
// 其余指标压缩成一行副信息。换页签 = 换主角。

struct PanelHeroView: View {
    @ObservedObject var store: MetricsStore
    var forceTab: ChartTab? = nil
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    private var tab: ChartTab { forceTab ?? tabState }

    private var chart: (values: [Double], maxV: Double, color: Color) {
        switch tab {
        case .cpu:  return (store.cpuSeries.values(for: .m1), 100, Dark.blue)
        case .mem:  return (store.memSeries.values(for: .m1), 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: .m1)
            return (v, max((v.max() ?? 50) + 5, 60), Dark.amber)
        }
    }

    private var big: (value: String, unit: String) {
        switch tab {
        case .cpu:
            return ("\(Int(store.cpu.total.rounded()))", "%")
        case .mem:
            return (Fmt.gbValue(store.memory.used), "GB")
        case .net:
            let r = Fmt.rate(store.network.down)
            return (r.0, r.1)
        case .disk:
            let r = Fmt.rate(store.disk.readBps)
            return (r.0, r.1)
        case .temp:
            return (store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—", "°C")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(chip: store.chipName, onOpen: onOpen)
            if let alert = store.alert {
                PanelAlertBanner(alert: alert) { store.dismissAlert() }
                    .padding(.top, 8)
            }

            subtleTabs.padding(.top, 14)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(big.value)
                    .font(.system(size: 50, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(chart.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(big.unit)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(chart.color.opacity(0.65))
            }
            .padding(.top, 2)

            PanelMiniChart(values: chart.values, maxV: chart.maxV, color: chart.color,
                           lineWidth: 1.8, fitToPeak: true)
                .frame(height: 84)
                .padding(.top, 4)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 12)

            HStack(spacing: 0) {
                mini("内存", "\(Fmt.gbValue(store.memory.used)) GB") { onOpen(.memory) }
                mini("温度", store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))°C" : "—") { onOpen(.sensor) }
                mini("网络", "\(Fmt.rate(store.network.down).0)\(Fmt.rate(store.network.down).1)") { onOpen(.network) }
                mini("磁盘", "\(Fmt.rate(store.disk.readBps).0)\(Fmt.rate(store.disk.readBps).1)") { onOpen(.disk) }
            }

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 12)

            PanelProcessList(store: store, compact: true, limit: 3)
            Spacer(minLength: 0)
            PanelFooter(store: store, onOpen: onOpen)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 342)
        .background(Dark.panel)
    }

    private var subtleTabs: some View {
        HStack(spacing: 14) {
            ForEach(ChartTab.allCases, id: \.self) { t in
                Button { withAnimation(.easeOut(duration: 0.12)) { tabState = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: 10, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Dark.text : Color.white.opacity(0.32))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func mini(_ title: String, _ value: String,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(Dark.faint)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Dark.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clickable(action)
    }
}

// MARK: - 方案 F：双环
//
// 两个大环当主视觉，剩下的指标退成一行小字。
// 环比前面那版大得多（86pt），中心数字用 20pt，扫一眼就能读。

struct PanelDualView: View {
    @ObservedObject var store: MetricsStore
    var forceTab: ChartTab? = nil
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    private var tab: ChartTab { forceTab ?? tabState }

    private var tempColor: Color {
        let t = store.sensor.cpuTemp
        if t >= 90 { return Dark.red }
        if t >= 75 { return Dark.amber }
        return Dark.blue
    }

    private var chart: (values: [Double], maxV: Double, color: Color) {
        switch tab {
        case .cpu:  return (store.cpuSeries.values(for: .m1), 100, Dark.blue)
        case .mem:  return (store.memSeries.values(for: .m1), 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: .m1)
            return (v, max((v.max() ?? 50) + 5, 60), Dark.amber)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(chip: store.chipName, onOpen: onOpen)
            if let alert = store.alert {
                PanelAlertBanner(alert: alert) { store.dismissAlert() }
                    .padding(.top, 8)
            }

            HStack(spacing: 0) {
                bigRing("CPU", "\(Int(store.cpu.total.rounded()))", "%",
                        store.cpu.total, Dark.load(store.cpu.total)) { onOpen(.cpu) }
                bigRing("内存", Fmt.gbValue(store.memory.used), "GB",
                        store.memory.ratio * 100, Dark.purple) { onOpen(.memory) }
            }
            .padding(.top, 14)

            HStack(spacing: 0) {
                Text("温度 \(store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))°C" : "—")")
                    .foregroundStyle(tempColor)
                    .clickable { onOpen(.sensor) }
                Spacer()
                Text("网络 ↓\(Fmt.rate(store.network.down).0)\(Fmt.rate(store.network.down).1)")
                    .foregroundStyle(Dark.dim)
                    .clickable { onOpen(.network) }
                Spacer()
                Text("磁盘 读\(Fmt.rate(store.disk.readBps).0)\(Fmt.rate(store.disk.readBps).1)")
                    .foregroundStyle(Dark.dim)
                    .clickable { onOpen(.disk) }
            }
            .font(.system(size: 9.5))
            .monospacedDigit()
            .padding(.top, 12)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 11)

            PanelTabs(tab: Binding(get: { tab }, set: { tabState = $0 }), range: .m1, dense: true)
            PanelMiniChart(values: chart.values, maxV: chart.maxV, color: chart.color,
                           fitToPeak: true)
                .frame(height: 62)
                .padding(.top, 7)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                .padding(.vertical, 11)

            PanelProcessList(store: store, compact: true, limit: 3)
            Spacer(minLength: 0)
            PanelFooter(store: store, onOpen: onOpen)
                .padding(.top, 10)
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 342)
        .background(Dark.panel)
    }

    private func bigRing(_ title: String, _ value: String, _ unit: String,
                         _ percent: Double, _ color: Color,
                         action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            ZStack {
                PanelRing(percent: percent, color: color, size: 86, width: 7)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Dark.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Text(unit)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Dark.faint)
                }
                .padding(.horizontal, 8)
            }
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(Dark.faint)
        }
        .frame(maxWidth: .infinity)
        .clickable(action)
    }
}

// MARK: - 方案 G：排版
//
// 不用卡片、不用圆环、不用分隔线堆层次。三个超大数字横排，
// 全靠字号对比和留白。信息密度最低，但看起来最干净。

struct PanelEditorialView: View {
    @ObservedObject var store: MetricsStore
    var forceTab: ChartTab? = nil
    var onOpen: (Section) -> Void = { _ in }

    @State private var tabState: ChartTab = .cpu
    private var tab: ChartTab { forceTab ?? tabState }

    private var tempColor: Color {
        let t = store.sensor.cpuTemp
        if t >= 90 { return Dark.red }
        if t >= 75 { return Dark.amber }
        return Dark.blue
    }

    private var chart: (values: [Double], maxV: Double, color: Color) {
        switch tab {
        case .cpu:  return (store.cpuSeries.values(for: .m1), 100, Dark.blue)
        case .mem:  return (store.memSeries.values(for: .m1), 100, Dark.purple)
        case .net:
            let v = store.netDownSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.green)
        case .disk:
            let v = store.diskRSeries.values(for: .m1)
            return (v, max(v.max() ?? 1, 1024), Dark.amber)
        case .temp:
            let v = store.tempSeries.values(for: .m1)
            return (v, max((v.max() ?? 50) + 5, 60), Dark.amber)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(chip: store.chipName, onOpen: onOpen)
            if let alert = store.alert {
                PanelAlertBanner(alert: alert) { store.dismissAlert() }
                    .padding(.top, 8)
            }

            HStack(alignment: .top, spacing: 0) {
                number("CPU", "\(Int(store.cpu.total.rounded()))", "%",
                       Dark.load(store.cpu.total)) { onOpen(.cpu) }
                number("内存", Fmt.gbValue(store.memory.used), "GB", Dark.purple) { onOpen(.memory) }
                number("温度",
                       store.sensor.cpuTemp > 0 ? "\(Int(store.sensor.cpuTemp.rounded()))" : "—",
                       "°C", tempColor) { onOpen(.sensor) }
            }
            .padding(.top, 18)

            PanelTabs(tab: Binding(get: { tab }, set: { tabState = $0 }), range: .m1, dense: true)
                .padding(.top, 18)

            PanelMiniChart(values: chart.values, maxV: chart.maxV, color: chart.color,
                           lineWidth: 1.5, fitToPeak: true)
                .frame(height: 54)
                .padding(.top, 8)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                .padding(.top, 12)

            HStack(spacing: 0) {
                Text("网络 ↓\(Fmt.rate(store.network.down).0) \(Fmt.rate(store.network.down).1) · ↑\(Fmt.rate(store.network.up).0) \(Fmt.rate(store.network.up).1)")
                    .foregroundStyle(Dark.dim)
                    .clickable { onOpen(.network) }
                Spacer()
                Text("磁盘 读\(Fmt.rate(store.disk.readBps).0) \(Fmt.rate(store.disk.readBps).1)")
                    .foregroundStyle(Dark.dim)
                    .clickable { onOpen(.disk) }
            }
            .font(.system(size: 9.5))
            .monospacedDigit()
            .padding(.top, 10)

            PanelProcessList(store: store, compact: true, limit: 3)
                .padding(.top, 14)

            Spacer(minLength: 0)
            PanelFooter(store: store, onOpen: onOpen)
                .padding(.top, 12)
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: 342)
        .background(Dark.panel)
    }

    private func number(_ title: String, _ value: String, _ unit: String, _ color: Color,
                        action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(Dark.faint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(Dark.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clickable(action)
    }
}

// MARK: - 告警条（新样式共用）
//
// 现有样式的告警条画在 DashboardView 里，新样式得自己带一份，
// 不然切过去之后告警就只剩菜单栏变色了。

struct PanelAlertBanner: View {
    let alert: AlertEvent
    var onDismiss: () -> Void

    var body: some View {
        let c = alert.level == .danger ? Dark.red : Dark.amber
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(c)
                .frame(width: 2.5, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(c)
                Text(alert.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(Dark.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)

            Button(action: onDismiss) {
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
}
