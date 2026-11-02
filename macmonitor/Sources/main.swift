import Cocoa
import SwiftUI
import Combine
import Carbon.HIToolbox

// MARK: - 自定义面板

final class MonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 应用委托

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let store = MetricsStore()
    /// 软件管理的状态。放在这里而不是窗口视图里：窗口关掉再打开不用重新扫盘，
    /// 调试参数 `--select` 也能直接驱动它
    let manager = ManagerStore()
    private var statusItem: NSStatusItem!
    private var panel: MonitorPanel!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var bag = Set<AnyCancellable>()
    private var detailWindow: NSWindow?
    private var lastRingPercent: Double = -1
    private var lastRingAlert: Int = -1

    private let panelWidth: CGFloat = 342
    private let panelHeight: CGFloat = 392
    private let panelHeightWithAlert: CGFloat = 437

    private var targetHeight: CGFloat {
        store.alert != nil ? panelHeightWithAlert : panelHeight
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        setupPanel()
        setupGlobalDismiss()
        registerHotKey()

        store.$cpu
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)

        // 菜单栏指标可切换，每个指标都要能驱动刷新
        store.$memory
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)

        store.$network
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)

        store.$sensor
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)

        // 告警条 / 详情页切换时，面板要跟着调整高度，否则内容会被裁掉
        store.$alert
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.adjustToTarget() }
            .store(in: &bag)

        store.start()

        // 调试：--section process 让窗口直接停在指定分区
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--section"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            store.windowSection = Section.named(ProcessInfo.processInfo.arguments[i + 1])
        }

        if ProcessInfo.processInfo.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.showPanel()
            }
        }

        // 调试：--select <名字> 自动在软件分区里选中一个应用，用来复现扫描流程
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--select"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            let query = ProcessInfo.processInfo.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.openWindow(.software)
                // 等应用列表真的出来再选，别用固定延时赌
                func waitAndSelect(_ tries: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if self.manager.apps.isEmpty && tries > 0 {
                            waitAndSelect(tries - 1)
                            return
                        }
                        if let app = self.manager.apps.first(where: {
                            $0.name.localizedCaseInsensitiveContains(query)
                        }) {
                            print("--select 命中：\(app.name)（\(app.path)）")
                            fflush(stdout)
                            self.manager.select(app.id)
                        } else {
                            print("--select 没找到「\(query)」，当前 \(self.manager.apps.count) 个应用")
                            fflush(stdout)
                        }
                    }
                }
                waitAndSelect(40)
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--stats-run") {
            let a = ProcessInfo.processInfo.arguments
            if a.contains("--open-window") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self else { return }
                    self.openWindow(self.store.windowSection)
                }
            }
            let start = Date()
            var next = 5.0
            let t = Timer(timeInterval: 0.4, repeats: true) { _ in
                let el = Date().timeIntervalSince(start)
                if el >= next {
                    let m = SelfStats.resident()
                    print(String(format: "%5.1fs  RSS %6.1f MB  CPU累计 %6.3fs",
                                 el, Double(m.0) / 1_048_576, SelfStats.cpuTime()))
                    next += 5
                }
                if el >= 30 {
                    let m = SelfStats.resident()
                    let cpu = SelfStats.cpuTime()
                    print(String(format: "\n平均 CPU %.2f%%   RSS %.1f MB",
                                 cpu / el * 100, Double(m.0) / 1_048_576))
                    exit(0)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }

        if ProcessInfo.processInfo.arguments.contains("--probe-toggle") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                func state(_ tag: String) {
                    print("\(tag): 面板=\(self.panel.isVisible)  详情窗口=\(self.detailWindow?.isVisible ?? false)")
                }
                state("初始")
                self.toggleMode(); state("第 1 次点击")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    state("第 1 次 +0.7s")
                    self.toggleMode(); state("第 2 次点击")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        state("第 2 次 +0.7s")
                        self.toggleMode(); state("第 3 次点击")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            state("第 3 次 +0.7s")
                            exit(0)
                        }
                    }
                }
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.showPanel()
                print("showPanel 后立即: visible=\(self.panel.isVisible) frame=\(self.panel.frame)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("+0.3s: visible=\(self.panel.isVisible) alert=\(self.store.alert != nil)")
                    if ProcessInfo.processInfo.arguments.contains("--probe-alert") {
                        self.store.alert = AlertEvent(title: "测试告警", detail: "验证面板是否会随告警条改变高度",
                                                      level: .warn)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    print("+1.0s: visible=\(self.panel.isVisible) frame=\(self.panel.frame)")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let b = self.statusItem.button, let w = b.window {
                        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                        print("statusItem 屏幕位置: x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))")
                        print("statusItem 标题: \(b.title)")
                        print("图标 template 模式: \(b.image?.isTemplate ?? false)（true 表示跟随菜单栏配色自适应）")
                    } else {
                        print("statusItem 未挂到窗口")
                    }
                    print("面板可见: \(self.panel.isVisible)")
                    print("面板尺寸: \(Int(self.panel.frame.width)) x \(Int(self.panel.frame.height))")
                    print("面板层级: \(self.panel.level.rawValue)")
                    print("CPU 采样: \(Int(self.store.cpu.total))%  P核 \(Int(self.store.cpu.pAvg))%  E核 \(Int(self.store.cpu.eAvg))%")
                    print("内存: \(Fmt.bytes(self.store.memory.used)) GB / 压力 \(self.store.memory.pressureText)")
                    print("进程数: \(self.store.processes.count)（系统 \(self.store.processes.filter { $0.isSystem }.count)）")
                    for p in self.store.processes.prefix(5) {
                        print("  pid \(p.pid)  \(p.name)  uid=\(p.uid)  cpu=\(String(format: "%.1f", p.cpu))%  mem=\(Fmt.size(p.mem))\(p.hasMetrics ? "" : "  [无指标]")")
                    }

                    if ProcessInfo.processInfo.arguments.contains("--probe-window") {
                        self.openWindow(.overview)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if let w = self.detailWindow {
                                print("详情窗口: visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)")
                                print("窗口内容视图: \(type(of: w.contentView!))")
                            } else {
                                print("详情窗口未创建")
                            }
                            exit(0)
                        }
                    } else {
                        exit(0)
                    }
                }
            }
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = Self.ringImage(percent: 0, tint: .black, template: true)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshStatus()
    }

    @objc private func statusClicked() {
        // 左键 = 在「精简版」和「详情版」之间来回切换
        // 右键 = 菜单
        let isRight = NSApp.currentEvent?.type == .rightMouseUp
        if isRight {
            showMenu()
        } else {
            toggleMode()
        }
    }

    /// 精简版（菜单栏下拉面板）↔ 详情版（独立窗口）互相切换
    func toggleMode() {
        let windowVisible = detailWindow?.isVisible ?? false

        if windowVisible {
            // 详情版 → 精简版
            detailWindow?.orderOut(nil)
            showPanel()
        } else if panel.isVisible {
            // 精简版 → 详情版
            hidePanel()
            openWindow(store.windowSection)
        } else {
            // 都没显示：从精简版开始
            showPanel()
        }
    }

    @objc private func menuOpenWindow() {
        openWindow(store.windowSection)
    }

    @objc private func menuOpenPanel() {
        showPanel()
    }

    private func showMenu() {
        let menu = NSMenu()
        let about = NSMenuItem(title: "Mac Monitor \(AppInfo.version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "切换到详情窗口", action: #selector(menuOpenWindow), keyEquivalent: "m")
        openItem.keyEquivalentModifierMask = [.option]
        openItem.target = self
        menu.addItem(openItem)

        let panelItem = NSMenuItem(title: "切换到精简面板", action: #selector(menuOpenPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)

        let processItem = NSMenuItem(title: "打开进程管理", action: #selector(menuOpenProcesses), keyEquivalent: "p")
        processItem.keyEquivalentModifierMask = [.option]
        processItem.target = self
        menu.addItem(processItem)

        let softwareItem = NSMenuItem(title: "打开软件管理", action: #selector(menuOpenSoftware), keyEquivalent: "s")
        softwareItem.keyEquivalentModifierMask = [.option]
        softwareItem.target = self
        menu.addItem(softwareItem)

        menu.addItem(.separator())

        // 菜单栏显示哪个指标
        let displayItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for m in StatusMetric.allCases {
            let item = NSMenuItem(title: m.rawValue, action: #selector(menuPickMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (store.statusMetric == m) ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        // 顺手能用的系统操作
        let toolsItem = NSMenuItem(title: "系统工具", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu()
        addTool(toolsMenu, "打开活动监视器", #selector(menuActivityMonitor))
        addTool(toolsMenu, "重启 Finder", #selector(menuRestartFinder))
        toolsMenu.addItem(.separator())
        addTool(toolsMenu, "清空 DNS 缓存（需授权）", #selector(menuFlushDNS))
        addTool(toolsMenu, "清空内存缓存（需授权）", #selector(menuPurge))
        toolsItem.submenu = toolsMenu
        menu.addItem(toolsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let prev = statusItem.menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = prev
    }

    private func addTool(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func menuOpenProcesses() {
        openWindow(.process)
    }

    @objc private func menuOpenSoftware() {
        openWindow(.software)
    }

    @objc private func menuPickMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = StatusMetric(rawValue: raw) else { return }
        store.statusMetric = metric
        refreshStatus()
    }

    @objc private func menuActivityMonitor() {
        ProcessActions.openActivityMonitor()
    }

    @objc private func menuRestartFinder() {
        ProcessActions.restartFinder()
    }

    @objc private func menuFlushDNS() {
        store.showToast("正在清空 DNS 缓存，请授权…")
        ProcessActions.flushDNS { [weak self] ok in
            self?.store.showToast(ok ? "DNS 缓存已清空" : "已取消或执行失败", ok: ok)
        }
    }

    @objc private func menuPurge() {
        store.showToast("正在回收内存缓存，请授权…")
        ProcessActions.purgeMemory { [weak self] ok in
            self?.store.showToast(ok ? "内存缓存已回收" : "已取消或执行失败", ok: ok)
        }
    }

    /// 按当前选中的指标刷新菜单栏图标与文字
    private func refreshStatus() {
        guard let button = statusItem.button else { return }

        var percent: Double = 0
        var title = "—"
        var alertColor: NSColor?

        switch store.statusMetric {
        case .cpu:
            percent = store.cpu.total
            title = "\(Int(percent.rounded()))%"
            if percent >= 95 { alertColor = .systemRed }
            else if percent >= 80 { alertColor = .systemOrange }

        case .memory:
            percent = store.memory.ratio * 100
            title = "\(Int(percent.rounded()))%"
            if percent >= 95 { alertColor = .systemRed }
            else if percent >= 88 { alertColor = .systemOrange }

        case .network:
            let bps = store.network.down + store.network.up
            let r = Fmt.rate(bps)
            title = "↓\(r.0)\(r.1.hasPrefix("MB") ? "M" : "K")"
            // 圆环没有天然上限，按 10 MB/s 折算，纯粹当活动指示
            percent = min(100, bps / (10 * 1_048_576) * 100)

        case .temp:
            let t = store.sensor.cpuTemp
            title = t > 0 ? "\(Int(t.rounded()))°" : "—"
            percent = t > 0 ? min(100, max(0, (t - 30) / 70 * 100)) : 0
            if t >= 90 { alertColor = .systemRed }
            else if t >= 80 { alertColor = .systemOrange }
        }

        // 关键：正常状态用 template 图像，让 macOS 按菜单栏实际配色自动着色
        // （浅色栏→黑、深色栏→白、彩色壁纸→白）。写死颜色会在同色壁纸上看不见。
        // 只有告警状态才切换成彩色，因为橙/红在绝大多数壁纸下都够醒目。
        //
        // 圆环按 0.5% 一档重绘：菜单栏指标可切换后，cpu/mem/net/temp 四条流都会
        // 触发刷新，每次都新建 NSImage 太浪费
        let rounded = (percent * 2).rounded() / 2
        let alertKey = alertColor == .systemRed ? 2 : (alertColor == .systemOrange ? 1 : 0)
        if rounded != lastRingPercent || alertKey != lastRingAlert {
            lastRingPercent = rounded
            lastRingAlert = alertKey
            button.image = alertColor.map {
                Self.ringImage(percent: rounded, tint: $0, template: false)
            } ?? Self.ringImage(percent: rounded, tint: .black, template: true)
        }

        // 文字交给系统着色：用纯 title 而不是 attributedTitle，
        // 这样文字颜色始终跟随菜单栏外观，不会出现同色隐形。
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        button.title = title
    }

    /// 画一个按占用比例填充的圆环图标。
    /// - template: true 时只用 alpha 通道（系统负责着色），false 时用指定颜色
    static func ringImage(percent: Double, tint: NSColor, template: Bool) -> NSImage {
        let size = NSSize(width: 17, height: 17)
        let img = NSImage(size: size, flipped: false) { rect in
            let lw: CGFloat = 2.3
            let r = rect.insetBy(dx: lw / 2 + 0.8, dy: lw / 2 + 0.8)

            // template 模式下透明度就是唯一可用的信息，轨道用低 alpha 表示
            let trackColor = template ? NSColor.black.withAlphaComponent(0.30)
                                      : tint.withAlphaComponent(0.30)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = lw
            trackColor.setStroke()
            track.stroke()

            let p = min(1, max(0, percent / 100))
            if p > 0.02 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                              radius: r.width / 2,
                              startAngle: 90,
                              endAngle: 90 - 360 * p,
                              clockwise: true)
                arc.lineWidth = lw
                arc.lineCapStyle = .round
                (template ? NSColor.black : tint).setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = template
        return img
    }

    // MARK: 面板

    private func setupPanel() {
        panel = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)

        // 不用 NSVisualEffectView 的毛玻璃：面板是半透明的话，
        // 浅色壁纸会透上来把白字冲淡，实测完全看不清。改成不透明深色底。
        let effect = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor(srgbRed: 0.082, green: 0.094, blue: 0.122, alpha: 1).cgColor
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        effect.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: DashboardView(store: store, onOpen: { [weak self] sec in self?.openWindow(sec) }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.setFrameSize(NSSize(width: panelWidth, height: panelHeight))
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        panel.contentView = effect
    }

    // MARK: 详情窗口（独立大窗口，深色专业监控界面）

    func openWindow(_ section: Section) {
        store.windowSection = section

        if let w = detailWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            hidePanel()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Mac Monitor"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(red: 0.043, green: 0.051, blue: 0.067, alpha: 1)
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 1000, height: 640)
        w.isReleasedWhenClosed = false
        w.center()

        let hosting = NSHostingView(rootView: MonitorWindowView(store: store, manager: manager))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor, constant: 0),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        w.contentView = container

        // 关闭后保留实例，再次打开能保持分区与窗口位置
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            self?.detailWindow = nil
        }

        detailWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hidePanel()
    }

    func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        guard let button = statusItem.button, let win = button.window else { return }

        // 先按当前是否带告警把高度设好，再定位，避免先闪一下再跳
        var f = panel.frame
        let h = targetHeight
        if abs(f.height - h) > 0.5 {
            let top = f.maxY
            f.size.height = h
            f.origin.y = top - h
            panel.setFrame(f, display: false)
        }

        let btnRect = button.convert(button.bounds, to: nil)
        let screenRect = win.convertToScreen(btnRect)
        let size = panel.frame.size

        var x = screenRect.midX - size.width / 2
        var y = screenRect.minY - size.height - 6

        if let screen = win.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
            if y < vis.minY + 8 { y = vis.minY + 8 }
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        store.panelVisible = true
    }

    /// 告警条出现 / 进入详情页时调整面板高度，保持顶边不动
    private func adjustToTarget() {
        guard panel.isVisible else { return }
        let target = targetHeight
        var f = panel.frame
        guard abs(f.height - target) > 0.5 else { return }
        let top = f.maxY
        f.size.height = target
        f.origin.y = top - target
        panel.setFrame(f, display: true, animate: true)
    }

    func hidePanel() {
        panel.orderOut(nil)
        store.panelVisible = false
    }

    private func setupGlobalDismiss() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.hidePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53, let self, self.panel.isVisible {   // ESC
                self.hidePanel()
                return nil
            }
            return e
        }
    }

    // MARK: 全局快捷键 ⌥M

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { AppDelegate.shared?.toggleMode() }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x4D4D_4F4E), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - 快照模式（用于导出界面预览图）

@MainActor
func renderSnapshot(store: MetricsStore, to path: String, tab: ChartTab? = nil) {
    let content = DashboardView(store: store, forceTab: tab)
        .background(Dark.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("snapshot failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("snapshot saved: \(path)  size=\(img.size)")
}

// MARK: - 菜单栏图标对比图（验证不同背景下的可读性）

@MainActor
func renderIconPreview(to path: String) {
    let states: [(String, Double)] = [("正常", 15), ("警告", 82), ("危险", 96)]
    let bgs: [(String, NSColor, NSColor)] = [
        ("浅色菜单栏", NSColor(calibratedWhite: 0.95, alpha: 1), NSColor.black),
        ("深色菜单栏", NSColor(calibratedWhite: 0.13, alpha: 1), NSColor.white),
        ("蓝色壁纸",   NSColor(calibratedRed: 0.09, green: 0.42, blue: 0.76, alpha: 1), NSColor.white)
    ]

    let cellW: CGFloat = 208
    let cellH: CGFloat = 96
    let margin: CGFloat = 26
    let headerH: CGFloat = 62
    let size = NSSize(width: margin * 2 + cellW * 3, height: headerH + cellH * 3 + margin)

    let img = NSImage(size: size)
    img.lockFocus()

    NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    func draw(_ s: String, at p: NSPoint, font: NSFont, color: NSColor) {
        s.draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    let subFont = NSFont.systemFont(ofSize: 10.5)
    let valFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    draw("菜单栏图标可读性对比", at: NSPoint(x: margin, y: size.height - 30), font: titleFont,
         color: NSColor(calibratedWhite: 0.15, alpha: 1))
    draw("正常状态用 template 图像由系统着色；只有告警才切彩色",
         at: NSPoint(x: margin, y: size.height - 46), font: subFont,
         color: NSColor(calibratedWhite: 0.5, alpha: 1))

    for (r, bg) in bgs.enumerated() {
        let rowY = size.height - headerH - CGFloat(r + 1) * cellH
        let band = NSRect(x: margin, y: rowY, width: cellW * 3, height: cellH - 10)
        bg.1.setFill()
        band.fill()

        draw(bg.0, at: NSPoint(x: margin + 10, y: rowY + 10), font: subFont,
             color: bg.2.withAlphaComponent(0.75))

        for (c, st) in states.enumerated() {
            let cx = margin + CGFloat(c) * cellW + cellW / 2 + 18
            let cy = rowY + band.height / 2 - 6

            let isAlert = st.1 >= 80
            let tint: NSColor = isAlert ? (st.1 >= 95 ? .systemRed : .systemOrange) : bg.2

            // 直接画成 template 图像被系统着色后的样子
            let ring = AppDelegate.ringImage(percent: st.1, tint: tint, template: false)
            ring.draw(in: NSRect(x: cx - 24, y: cy - 8, width: 17, height: 17))

            draw("\(Int(st.1))%", at: NSPoint(x: cx - 4, y: cy - 8), font: valFont, color: bg.2)

            let note = isAlert ? (st.1 >= 95 ? "红 · 固定色" : "橙 · 固定色") : "随背景反色"
            draw(note, at: NSPoint(x: cx - 24, y: cy - 24), font: NSFont.systemFont(ofSize: 9),
                 color: bg.2.withAlphaComponent(0.6))
        }
    }

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("icon preview failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("icon preview saved: \(path) size=\(img.size)")
}

// MARK: - 应用图标（打包用）
//
// 用代码画而不是塞一张 PNG：图标和菜单栏圆环同一套设计语言，
// 而且每个尺寸都是原生渲染，16px 也不会糊成一团。

/// 在指定像素尺寸的位图里画出图标本体（坐标系原点在左下）
@MainActor
private func drawAppIcon(in size: CGFloat) {
    let inset = size * 0.055
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // 底色沿用详情窗口的深色渐变
    NSGradient(starting: NSColor(srgbRed: 0.145, green: 0.169, blue: 0.212, alpha: 1),
               ending: NSColor(srgbRed: 0.043, green: 0.051, blue: 0.067, alpha: 1))?
        .draw(in: shape, angle: -90)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: size * 0.004, dy: size * 0.004),
                              xRadius: radius, yRadius: radius)
    border.lineWidth = max(1, size * 0.008)
    border.stroke()

    // 进度环：和菜单栏图标同一个隐喻
    let ringInset = size * 0.245
    let ring = NSRect(x: ringInset, y: ringInset,
                      width: size - ringInset * 2, height: size - ringInset * 2)
    let lw = size * 0.058

    let track = NSBezierPath(ovalIn: ring.insetBy(dx: lw / 2, dy: lw / 2))
    track.lineWidth = lw
    NSColor.white.withAlphaComponent(0.12).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2),
                  radius: ring.width / 2 - lw / 2,
                  startAngle: 90, endAngle: 90 - 360 * 0.72, clockwise: true)
    arc.lineWidth = lw
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.298, green: 0.604, blue: 1.0, alpha: 1).setStroke()
    arc.stroke()

    // 中央字母
    var font = NSFont.systemFont(ofSize: size * 0.30, weight: .bold)
    if let desc = font.fontDescriptor.withDesign(.rounded),
       let rounded = NSFont(descriptor: desc, size: size * 0.30) {
        font = rounded
    }
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let text = "M" as NSString
    let ts = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size - ts.width) / 2, y: (size - ts.height) / 2 + size * 0.012),
              withAttributes: attrs)
}

@MainActor
private func appIconPNG(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawAppIcon(in: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

/// 生成 iconutil 需要的 .iconset 目录
@MainActor
func renderIconset(to dir: String) {
    let specs: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, px) in specs {
        guard let data = appIconPNG(size: px) else { continue }
        try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
    print("iconset saved: \(dir)")
}

@MainActor
func renderAppIcon(to path: String, size: Int) {
    guard let data = appIconPNG(size: size) else {
        print("app icon failed")
        return
    }
    try? data.write(to: URL(fileURLWithPath: path))
    print("app icon saved: \(path) \(size)x\(size)")
}

// MARK: - 详情窗口快照

@MainActor
func renderWindowSnapshot(store: MetricsStore, to path: String) {
    let content = MonitorWindowView(store: store, snapshotMode: true, manager: ManagerStore())
        .frame(width: 1060, height: 690)
        .background(Dark.bg)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("window snapshot failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("window snapshot saved: \(path)  size=\(img.size)")
}

// MARK: - 自测量（进程自身的资源占用）

enum SelfStats {
    static func resident() -> (UInt64, UInt64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.resident_size, info.virtual_size)
    }

    static func cpuTime() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
             + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }
}

// MARK: - 入口

let args = ProcessInfo.processInfo.arguments
let app = NSApplication.shared

// MARK: 软件管家原有的调试入口（并进来之后参数名保持不变）

if args.contains("--selftest") {
    app.setActivationPolicy(.prohibited)
    SelfTest.run()
    exit(0)
}

if let i = args.firstIndex(of: "--orphans") {
    app.setActivationPolicy(.prohibited)
    let all = args.count > i + 1 && args[i + 1] == "all"
    SelfTest.dumpOrphans(includeMedium: all)
    exit(0)
}

if args.contains("--recommend") {
    app.setActivationPolicy(.prohibited)
    SelfTest.dumpRecommend()
    exit(0)
}

if let i = args.firstIndex(of: "--scan-timing") {
    app.setActivationPolicy(.prohibited)
    let query = args.count > i + 1 ? args[i + 1] : ""
    Scanner.timingReport(query)
    exit(0)
}

if let i = args.firstIndex(of: "--stats") {
    let seconds = (args.count > i + 1 ? Double(args[i + 1]) : nil) ?? 30
    app.setActivationPolicy(.prohibited)
    let store = MetricsStore()
    store.panelVisible = true
    if !args.contains("--no-sample") { store.start() }

    var statWindow: NSWindow?
    if args.contains("--with-window") {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 690),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        if args.contains("--plain-window") {
            w.contentView = NSHostingView(rootView: Text("test").frame(width: 400, height: 300))
        } else {
            w.contentView = NSHostingView(rootView: MonitorWindowView(store: store, manager: ManagerStore()))
        }
        if !args.contains("--window-hidden") { w.orderFront(nil) }
        statWindow = w
        print("（详情窗口已打开）")
    }

    print("已运行(s)   RSS(MB)   虚拟(MB)   CPU累计(s)")
    let start = Date()
    var nextReport = 0.0
    while Date().timeIntervalSince(start) < seconds {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let el = Date().timeIntervalSince(start)
        if el >= nextReport {
            let m = SelfStats.resident()
            print(String(format: "%8.1f   %7.1f   %8.1f   %8.3f",
                         el, Double(m.0) / 1_048_576, Double(m.1) / 1_048_576, SelfStats.cpuTime()))
            nextReport += 5
        }
    }
    let m = SelfStats.resident()
    let cpu = SelfStats.cpuTime()
    print(String(format: "\n平均 CPU：%.2f%%（%.3fs / %.0fs，采样间隔 2 秒）", cpu / seconds * 100, cpu, seconds))
    print(String(format: "峰值 RSS：%.1f MB", Double(m.0) / 1_048_576))
    _ = statWindow
    exit(0)
}

if let i = args.firstIndex(of: "--iconset"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        renderIconset(to: args[i + 1])
    }
    exit(0)
} else if let i = args.firstIndex(of: "--app-icon"), i + 1 < args.count {
    let px = (args.count > i + 2 ? Int(args[i + 2]) : nil) ?? 1024
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        renderAppIcon(to: args[i + 1], size: px)
    }
    exit(0)
} else if let i = args.firstIndex(of: "--icon-preview"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        renderIconPreview(to: args[i + 1])
    }
    exit(0)
} else if let i = args.firstIndex(of: "--window"), i + 1 < args.count {
    let outPath = args[i + 1]
    let sectionName = args.count > i + 2 ? args[i + 2] : "overview"
    app.setActivationPolicy(.prohibited)
    let store = MetricsStore()
    store.panelVisible = true
    store.samplingInterval = 0.4

    store.windowSection = Section.named(sectionName)

    store.start()
    let deadline = Date().addingTimeInterval(16)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    MainActor.assumeIsolated {
        renderWindowSnapshot(store: store, to: outPath)
    }
    exit(0)
} else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let outPath = args[i + 1]
    app.setActivationPolicy(.prohibited)
    let store = MetricsStore()
    store.panelVisible = true
    store.samplingInterval = 0.4
    store.start()

    // 跑 16 秒，让历史曲线有足够数据点
    let deadline = Date().addingTimeInterval(16)
    let demoAlert = args.contains("--demo-alert")
    let forceTab: ChartTab? = args.contains("--tab-temp") ? .temp : nil

    var injected = false
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if demoAlert, !injected, Date() > deadline.addingTimeInterval(-6) {
            injected = true
            store.alert = AlertEvent(title: "内存压力偏高",
                                     detail: "系统内存压力进入「警告」，Swap 4.7 GB",
                                     level: .warn)
        }
    }
    MainActor.assumeIsolated {
        renderSnapshot(store: store, to: outPath, tab: forceTab)
    }

    // 自测：报告采样引擎自身的 CPU 开销
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let cpuTime = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
                + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    print(String(format: "采样引擎自身开销: %.3fs CPU / 16s 墙钟 = %.2f%%（采样间隔 0.4s，是生产环境 2s 的 5 倍频）",
                 cpuTime, cpuTime / 16 * 100))
    exit(0)
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
