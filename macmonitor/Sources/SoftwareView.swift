import SwiftUI

// MARK: - 软件管理（整合自 mac-software-manager / Mac软件管家）

/// 把软件管家的主界面接进监测窗口。
///
/// 管家原本是个独立窗口（`@main` + `WindowGroup`），并入后只保留它的
/// `ContentView`，入口由 `Section.software` 提供。
///
/// `ManagerStore` 由 `MonitorWindowView` 持有，而不是放在这里用 `@StateObject`：
/// 后者会在每次切走分区时销毁，切回来就要重新全盘扫描一遍（Spotlight + 逐个体积），
/// 代价太大。
struct SoftwareView: View {
    @ObservedObject var store: ManagerStore

    var body: some View {
        ContentView()
            .environmentObject(store)
            // 管家整体用「系统语义色 + windowBackgroundColor」，本身不写死颜色，
            // 所以这里把 colorScheme 钉成 dark：窗口是 darkAqua 时两处一致，
            // 离屏渲染（ImageRenderer）也能拿到深色底，不会导出成白底。
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
    }
}

extension SoftwareView: Equatable {
    /// 只比对象身份。配合 `.equatable()` 使用：
    /// 监测侧的指标每 2 秒刷新一次，`MonitorWindowView` 会整棵重新求值，
    /// 不做这个比较的话，软件页那 78 行列表每 2 秒就要重排一遍——纯属白烧 CPU。
    static func == (lhs: SoftwareView, rhs: SoftwareView) -> Bool {
        lhs.store === rhs.store
    }
}
