import Foundation
import Security

struct RuleTemplate: Codable {
    let path: String
    let kind: String?
    let confidence: String
    let label: String
    let privileged: Bool?
}

struct RuleGlob: Codable {
    let pattern: String
    let kind: String?
    let confidence: String
    let label: String
    let privileged: Bool?
}

struct Rules: Codable {
    let templates: [RuleTemplate]
    let globs: [RuleGlob]
    let keepConfigLabels: [String]

    enum CodingKeys: String, CodingKey {
        case templates, globs
        case keepConfigLabels = "keep_config_labels"
    }

    static let empty = Rules(templates: [], globs: [], keepConfigLabels: [])
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// `/System/Applications` 也要扫：不带它的话「系统软件占了多少」这个数就是假的，
    /// 而 Notes、Music、Maps 这些 60 多个应用全在那里。它们会在界面上单独分组并禁用卸载。
    static let appRoots = ["/Applications", "\(home)/Applications", "/System/Applications"]

    // MARK: - 规则加载

    static func loadRules() -> Rules {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "rules", withExtension: "json") {
            candidates.append(url)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("rules.json"))
        candidates.append(exeDir.appendingPathComponent("Resources/rules.json"))

        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let rules = try? JSONDecoder().decode(Rules.self, from: data) {
                return rules
            }
        }
        return .empty
    }

    // MARK: - 应用发现

    static func discoverApps() -> [ManagedApp] {
        var seen = Set<String>()
        var results: [ManagedApp] = []

        for root in appRoots {
            let rootURL = URL(fileURLWithPath: root)
            guard FileManager.default.fileExists(atPath: root) else { continue }
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let en = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: nil
            ) else { continue }

            for case let url as URL in en {
                if url.pathExtension.lowercased() == "app" {
                    en.skipDescendants()
                    let path = url.path
                    // 别把自己列进可卸载清单，卸载自己没有任何意义
                    if path == Safety.appBundlePath { continue }
                    if !seen.contains(path) {
                        seen.insert(path)
                        results.append(loadApp(path))
                    }
                }
            }
        }

        // 别把自己列进可卸载清单（不管是当前运行的副本还是 /Applications 里那份）
        let ownID = Bundle.main.bundleIdentifier
        return results
            .filter { ownID == nil || $0.bundleID != ownID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func loadApp(_ path: String) -> ManagedApp {
        var info: [String: Any] = [:]
        let infoPath = path + "/Contents/Info.plist"
        if let data = FileManager.default.contents(atPath: infoPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plist as? [String: Any] {
            info = dict
        }
        let fallbackName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fallbackName
        return ManagedApp(
            path: path,
            name: name,
            bundleID: (info["CFBundleIdentifier"] as? String) ?? "",
            version: (info["CFBundleShortVersionString"] as? String) ?? ""
        )
    }

    // MARK: - 体积

    /// 调试用：`--scan-timing` 打开后记录每次体积计算的耗时
    static var timingEnabled = false
    nonisolated(unsafe) static var slowSizes: [(path: String, seconds: Double, files: Int)] = []
    private static let timingLock = NSLock()

    // 体积缓存。
    //
    // 冷缓存遍历一个 686 MB 的容器要 5 秒（`du` 实测），热缓存 0.17 秒，
    // 差 30 倍。而同一个目录在一次会话里会被反复问：
    // 刷新列表的 enrich 要问一次、点开应用要问一次、切走再切回来又问一次。
    // 缓存 5 分钟，删除操作后整体失效。
    private static let sizeCacheLock = NSLock()
    nonisolated(unsafe) private static var sizeCache: [String: (bytes: Int64, at: Date)] = [:]
    private static let sizeCacheTTL: TimeInterval = 300

    static func clearSizeCache() {
        sizeCacheLock.lock()
        sizeCache.removeAll()
        sizeCacheLock.unlock()

        pkgIDCacheLock.lock()
        pkgIDCache.removeAll()
        pkgIDCacheLock.unlock()
    }

    private static func cachedSize(_ path: String) -> Int64? {
        sizeCacheLock.lock()
        defer { sizeCacheLock.unlock() }
        guard let hit = sizeCache[path] else { return nil }
        if Date().timeIntervalSince(hit.at) > sizeCacheTTL {
            sizeCache[path] = nil
            return nil
        }
        return hit.bytes
    }

    private static func storeSize(_ path: String, _ bytes: Int64) {
        sizeCacheLock.lock()
        sizeCache[path] = (bytes, Date())
        sizeCacheLock.unlock()
    }

    /// 目录占用（已分配大小，和 `du` 一个口径）。
    ///
    /// 不用 `FileManager.enumerator` + `URLResourceValues`：那样每个文件要过一次
    /// `URL` → `NSURL` → `getattrlist`，微信容器 3739 个文件实测 383 ms。
    /// 这里换成 `fts(3)`——`du` 自己就是这么走的，一次 `getattrlistbulk` 拿一批
    /// 目录项，`fts_statp` 直接带着 `st_blocks`，不用再 stat。
    static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        if let hit = cachedSize(path) { return hit }

        let started = timingEnabled ? Date() : nil
        let (total, files) = walkSize(path)
        storeSize(path, total)
        if let started {
            let dt = Date().timeIntervalSince(started)
            timingLock.lock()
            slowSizes.append((path, dt, files))
            timingLock.unlock()
        }
        return total
    }

    /// `fts` 遍历：FTS_PHYSICAL 不跟随符号链接，跳过目录本身，只累加普通文件。
    private static func walkSize(_ path: String) -> (bytes: Int64, files: Int) {
        guard let cPath = strdup(path) else { return (0, 0) }
        defer { free(cPath) }

        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        let stream: UnsafeMutablePointer<FTS>? = argv.withUnsafeMutableBufferPointer {
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil)
        }
        guard let stream else { return (0, 0) }
        defer { fts_close(stream) }

        var total: Int64 = 0
        var files = 0
        while let ent = fts_read(stream) {
            let node = ent.pointee
            // FTS_F = 8：普通文件；FTS_NS/FTS_ERR/FTS_DNR 是读不到的，跳过
            guard node.fts_info == FTS_F, let stat = node.fts_statp else { continue }
            total += Int64(stat.pointee.st_blocks) * 512
            files += 1
        }
        return (total, files)
    }

    /// 磁盘总容量与可用空间，用于算「这个应用占硬盘多少」
    static func diskInfo() -> (capacity: Int64, free: Int64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) else { return (0, 0) }
        return (Int64(values.volumeTotalCapacity ?? 0),
                values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: - 全盘应用索引
    /// 已安装应用索引：bundle id 集合 + 名称集合。
    ///
    /// **必须用 Spotlight 全盘找，不能只看 /Applications。**
    /// 真实事故：微信装在 `~/Library/Mobile Documents/.../WeChat.app`（iCloud 里），
    /// 只扫两个目录就认为"微信没装"，于是它 12 GB 的容器被判成残留删掉了。
    static func installedIndex() -> (bundleIDs: Set<String>, names: Set<String>) {
        var bundleIDs = Set<String>()
        var names = Set<String>()

        func absorb(path: String) {
            let url = URL(fileURLWithPath: path)
            let file = url.deletingPathExtension().lastPathComponent
            if !file.isEmpty { names.insert(file.lowercased()) }
            let infoPath = path + "/Contents/Info.plist"
            guard let data = FileManager.default.contents(atPath: infoPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any] else { return }
            if let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty {
                bundleIDs.insert(id.lowercased())
            }
            for key in ["CFBundleName", "CFBundleDisplayName"] {
                if let name = dict[key] as? String, !name.isEmpty { names.insert(name.lowercased()) }
            }
            if let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty {
                names.insert(exe.lowercased())
            }
        }

        for app in discoverApps() {
            if !app.bundleID.isEmpty { bundleIDs.insert(app.bundleID.lowercased()) }
            names.insert(app.name.lowercased())
            absorb(path: app.path)
        }

        // Spotlight 索引里的所有 .app，包含装在 iCloud、Documents、任意目录的
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                let path = String(line)
                guard path.hasSuffix(".app"), !path.hasPrefix("/Volumes/") else { continue }
                absorb(path: path)
            }
        } catch {
            // 拿不到 Spotlight 也不致命，退回只认 /Applications
        }

        return (bundleIDs, names)
    }

    // MARK: - 应用画像（最后使用 / 数据 / 缓存 / 系统判定）

    /// 一次补齐所有派生字段。四个功能（最后使用时间、缓存、占比、推荐）共用这一遍扫描，
    /// 不再为每个功能单独遍历目录。
    static func enrich(_ app: inout ManagedApp) {
        // 调用方可能只拿 discoverApps() 的结果，本体体积还没算
        if app.size == 0 { app.size = size(of: app.path) }
        let (used, source) = lastUsed(for: app)
        app.lastUsed = used
        app.usageSource = source
        app.cacheSize = cacheSize(for: app)
        app.dataSize = dataSize(for: app)
        let signed = appleSigned(app.path)
        app.isAppleSigned = signed
        app.isSystem = isSystemApp(path: app.path, bundleID: app.bundleID, appleSigned: signed)
    }

    /// 最后使用时间，三路兜底取最早可信的那个。
    ///
    /// macOS 没有「应用上次启动时间」的公开 API。实测全盘 338 个 .app 里，
    /// Spotlight 的 `kMDItemLastUsedDate` 只覆盖 28 个（8%），Safari、Music 这些
    /// 系统应用全是 null——它们不走 LaunchServices 常规启动。所以必须有兜底：
    ///
    /// 1. Spotlight 记录（精确到秒，最可信，但覆盖低）
    /// 2. 应用数据目录的最新修改时间（应用一跑就写缓存/偏好设置，覆盖约一半）
    /// 3. 应用本体修改时间（只说明安装/更新时间，标成不可信）
    static func lastUsed(for app: ManagedApp) -> (Date?, UsageSource) {
        if let date = spotlightLastUsed(app.path) {
            return (date, .spotlight)
        }
        if let date = dataActivity(app) {
            return (date, .activity)
        }
        if let date = modificationDate(app.path) {
            return (date, .install)
        }
        return (nil, .unknown)
    }

    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: path)) else { return nil }
        return item.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }

    /// 应用一运行就会写容器、缓存、偏好设置。取这些位置里最新的修改时间当「最后活动时间」。
    ///
    /// 只看到目录本身和它的第一层子项——再往深走要递归，338 个应用会拖到好几秒，
    /// 而精度对「多久没用」这个判断没有意义。所以这个值在界面上标「数据活跃」，不冒充系统记录。
    static func dataActivity(_ app: ManagedApp) -> Date? {
        var newest: Date?
        for path in activityPaths(app) {
            guard let date = latestActivity(path) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    static func activityPaths(_ app: ManagedApp) -> [String] {
        var paths: [String] = []
        if !app.bundleID.isEmpty {
            paths += [
                "\(home)/Library/Containers/\(app.bundleID)",
                "\(home)/Library/Caches/\(app.bundleID)",
                "\(home)/Library/Application Support/\(app.bundleID)",
                "\(home)/Library/Preferences/\(app.bundleID).plist",
                "\(home)/Library/Saved Application State/\(app.bundleID).savedState",
                "\(home)/Library/HTTPStorages/\(app.bundleID)",
                "\(home)/Library/WebKit/\(app.bundleID)"
            ]
        }
        for name in Set([app.name, executableName(app.path)]) where !name.isEmpty {
            paths += [
                "\(home)/Library/Application Support/\(name)",
                "\(home)/Library/Caches/\(name)",
                "\(home)/Library/Preferences/\(name).plist"
            ]
        }
        return paths
    }

    /// 目录本身的 mtime + 第一层子项的 mtime，取最大
    static func latestActivity(_ path: String) -> Date? {
        var newest = modificationDate(path)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return newest
        }
        for entry in entries.prefix(200) {
            guard let date = modificationDate(path + "/" + entry) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// 可清理的缓存：独立的 `~/Library/Caches/<bundle id>`，以及 Group Containers 里的缓存。
    /// 沙盒容器内部的 `Data/Library/Caches` 算进 dataSize，这里不重复计。
    static func cacheSize(for app: ManagedApp) -> Int64 {
        var paths: [String] = []
        if !app.bundleID.isEmpty {
            paths.append("\(home)/Library/Caches/\(app.bundleID)")
        }
        for name in Set([app.name, executableName(app.path)]) where !name.isEmpty {
            paths.append("\(home)/Library/Caches/\(name)")
        }
        paths += groupContainerCaches(app)
        return dedupedSize(paths)
    }

    /// 应用数据：沙盒容器、Application Support、偏好设置、保存状态、WebKit 存储
    static func dataSize(for app: ManagedApp) -> Int64 {
        var paths: [String] = []
        if !app.bundleID.isEmpty {
            paths += [
                "\(home)/Library/Containers/\(app.bundleID)",
                "\(home)/Library/Application Support/\(app.bundleID)",
                "\(home)/Library/Saved Application State/\(app.bundleID).savedState",
                "\(home)/Library/HTTPStorages/\(app.bundleID)",
                "\(home)/Library/WebKit/\(app.bundleID)",
                "\(home)/Library/Preferences/\(app.bundleID).plist"
            ]
        }
        for name in Set([app.name, executableName(app.path)]) where !name.isEmpty {
            paths += [
                "\(home)/Library/Application Support/\(name)",
                "\(home)/Library/Preferences/\(name).plist"
            ]
        }
        return dedupedSize(paths)
    }

    /// 同一个路径可能被 bundle id 和名字同时命中，符号链接也可能指到同一处
    static func dedupedSize(_ paths: [String]) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for path in paths {
            let key = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(key).inserted else { continue }
            total += size(of: path)
        }
        return total
    }

    static func groupContainerCaches(_ app: ManagedApp) -> [String] {
        let root = "\(home)/Library/Group Containers"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let bid = app.bundleID.lowercased()
        guard !bid.isEmpty else { return [] }
        var hits: [String] = []
        for entry in entries {
            // 目录名是 `<10 位团队 ID>.<bundle id>` 或 `group.<bundle id>`
            let low = entry.lowercased()
            let bare = OrphanScanner.stripContainerPrefix(entry).lowercased()
            guard low == bid || bare == bid || low.hasSuffix("." + bid) else { continue }
            let cache = root + "/" + entry + "/Library/Caches"
            if FileManager.default.fileExists(atPath: cache) { hits.append(cache) }
        }
        return hits
    }

    // MARK: - 系统软件识别

    /// 系统软件判定。三个信号取并集：
    /// 1. 解析符号链接后落在 `/System` 或 `/Library/Apple`——`/Applications/Safari.app`
    ///    其实是指向 `/System/Cryptexes/.../Safari.app` 的链接，只看路径前缀会漏
    /// 2. bundle id 以 `com.apple.` 开头
    /// 3. Apple 平台签名（`macOS Software Signing` 证书）
    static func isSystemApp(path: String, bundleID: String, appleSigned: Bool) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        if resolved.hasPrefix("/System/") { return true }
        if resolved.hasPrefix("/Library/Apple/") { return true }
        if bundleID.hasPrefix("com.apple.") { return true }
        return appleSigned
    }

    /// 是否 Apple 平台签名。
    ///
    /// 不用 `codesign` 子进程——338 个应用要 7.4 秒。进程内 `SecStaticCode` 只要 1.1 秒，
    /// 而且能直接拿到叶子证书的 subject：Apple 平台组件是 `macOS Software Signing`，
    /// 第三方是 `Developer ID Application: <公司> (<团队 ID>)`。
    static func appleSigned(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return false }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        return subject.contains("Software Signing")
    }

    // MARK: - 残留扫描

    /// 扫描结果分两步产出：
    ///
    /// 1. `collect` 只把「候选路径」凑齐，几乎不碰磁盘（毫秒级）
    /// 2. `assemble` 填体积，多核并行
    ///
    /// 中间通过 `onPartial` 先甩一份「清单已就绪、体积待填」的结果出去。
    /// 冷缓存下遍历一个 686 MB 的容器要好几秒（`du` 实测 5.2s），
    /// 界面不该为这个一直转圈。
    struct Collected {
        var app: ManagedApp
        var candidates: [Candidate]
        var notes: [String]
        var appItem: ResidueItem
        var local: [ResidueItem]
    }

    static func collect(_ app: ManagedApp, includeLow: Bool) -> Collected {
        let rules = loadRules()
        var notes: [String] = []

        // 只收集候选路径，不碰体积。
        // 之前是先 makeItem（顺手把体积算完）再按解析后的路径去重，
        // 结果是同一个目录被整棵遍历两遍——微信容器 3739 个文件，
        // 383 ms + 185 ms，白白多花一半时间。
        var candidates: [String: Candidate] = [:]

        func offer(_ candidate: Candidate?) {
            guard let candidate else { return }
            if candidate.path == app.path || candidate.path.hasPrefix(app.path + "/") { return }
            let key = (candidate.path as NSString).resolvingSymlinksInPath
            guard let existing = candidates[key] else {
                candidates[key] = candidate
                return
            }
            // 同一个路径被多条规则命中时，取更保守（置信度更低）的那个标签
            if candidate.confidence < existing.confidence {
                candidates[key] = Candidate(path: existing.path, label: existing.label,
                                            confidence: candidate.confidence)
            }
        }

        let ctx: [String: String] = [
            "name": app.name,
            "bundle_name": app.name,
            "bundle_id": app.bundleID
        ]

        for tpl in rules.templates {
            if tpl.path.contains("{bundle_id}") && app.bundleID.isEmpty { continue }
            guard let filled = fill(tpl.path, ctx) else { continue }
            offer(candidate(filled, label: tpl.label,
                            confidence: Confidence(rawValue: tpl.confidence) ?? .medium))
        }

        for glob in rules.globs {
            if glob.pattern.contains("{bundle_id}") && app.bundleID.isEmpty { continue }
            guard let filled = fill(glob.pattern, ctx) else { continue }
            for hit in expandGlob(filled) {
                offer(candidate(hit, label: glob.label,
                                confidence: Confidence(rawValue: glob.confidence) ?? .medium))
            }
        }

        if includeLow {
            for path in groupContainers(app) {
                offer(candidate(path, label: "共享容器", confidence: .low))
            }
            for path in fuzzyDirs(app) {
                offer(candidate(path, label: "疑似数据目录", confidence: .low))
            }
        }

        let pkg = pkgResidues(app)
        for item in pkg.items { offer(item) }
        notes.append(contentsOf: pkg.notes)
        // 收据只查一次：pkgResidues 内部已经调过 pkgutil --file-info，
        // 以前这里又调一遍，白搭一次进程启动
        if !app.bundleID.isEmpty, let id = pkg.pkgID {
            notes.append("安装包收据：\(id)（卸载后可执行 pkgutil --forget \(id) 清理）")
        }

        let appItem = ResidueItem(
            path: app.path,
            label: "应用程序",
            confidence: .high,
            size: app.size > 0 ? app.size : size(of: app.path),
            privileged: Safety.needsAdmin(app.path),
            selected: true
        )

        return Collected(
            app: app,
            candidates: Array(candidates.values),
            notes: notes,
            appItem: appItem,
            local: localFiles(for: app)
        )
    }

    /// `sizes` 传 nil 表示「体积还没算」，先给个占位
    static func assemble(_ collected: Collected, sizes: [Int64]?) -> ScanPlan {
        var notes = collected.notes

        var items: [ResidueItem]
        if let sizes, sizes.count == collected.candidates.count {
            items = zip(collected.candidates, sizes).map { candidate, bytes in
                ResidueItem(
                    path: candidate.path,
                    label: candidate.label,
                    confidence: candidate.confidence,
                    size: bytes,
                    privileged: Safety.needsAdmin(candidate.path)
                )
            }
            items.sort { $0.size > $1.size }
        } else {
            items = collected.candidates.map { candidate in
                ResidueItem(
                    path: candidate.path,
                    label: candidate.label,
                    confidence: candidate.confidence,
                    size: 0,
                    privileged: Safety.needsAdmin(candidate.path)
                )
            }
        }

        var privileged: [ResidueItem] = []
        var clean: [ResidueItem] = []
        for item in items {
            let result = Safety.check(item.path)
            if !result.ok {
                notes.append("受保护，不会删除（\(result.reason)）：\(item.path)")
                continue
            }
            if item.privileged {
                privileged.append(item)
            } else {
                clean.append(item)
            }
        }

        return ScanPlan(
            app: collected.app,
            appItem: collected.appItem,
            items: clean,
            privileged: privileged,
            notes: notes,
            localFiles: collected.local,
            sizesPending: sizes == nil
        )
    }

    static func scan(_ app: ManagedApp, includeLow: Bool,
                     onPartial: ((ScanPlan) -> Void)? = nil) -> ScanPlan {
        let collected = collect(app, includeLow: includeLow)

        if let onPartial {
            onPartial(assemble(collected, sizes: nil))
        }

        // 各目录互不重叠，拆开算没有依赖，多核能把「几个大容器」摊到几路
        let unique = collected.candidates
        var sizes = [Int64](repeating: 0, count: unique.count)
        if !unique.isEmpty {
            sizes.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: unique.count) { i in
                    buffer[i] = size(of: unique[i].path)
                }
            }
        }
        return assemble(collected, sizes: sizes)
    }

    // MARK: - 用户自己创建的本地文件

    /// 应用在 `~/Documents`、`~/Desktop`、`~/Downloads` 等位置留下的东西。
    /// 只负责列出来，默认不勾选，删除时也只允许移入废纸篓。
    static func localFiles(for app: ManagedApp) -> [ResidueItem] {
        let fm = FileManager.default
        var tokens = Set<String>()

        func addToken(_ text: String) {
            let t = text.lowercased().trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { return }
            // 纯英文的短词太容易误伤（比如 App 名 "Zy"），要求至少 4 个字符
            if t.allSatisfy({ $0.isASCII }) && t.count < 4 { return }
            tokens.insert(t)
        }

        addToken(app.name)
        addToken(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
        addToken(executableName(app.path))
        if !app.bundleID.isEmpty {
            addToken(app.bundleID)
            let parts = app.bundleID.split(separator: ".")
            if parts.count >= 2 { addToken(String(parts[1])) }
        }
        for suffix in ["免费版", "专业版", "客户端", "桌面版", "企业版"] where app.name.hasSuffix(suffix) {
            addToken(String(app.name.dropLast(suffix.count)))
        }
        guard !tokens.isEmpty else { return [] }

        // 安装包不是应用留下的数据，别混进来
        let installerExtensions: Set<String> = [
            "dmg", "pkg", "zip", "apk", "exe", "msi", "tar", "gz", "xz", "7z", "iso", "crx", "rar"
        ]

        var results: [ResidueItem] = []
        for root in Safety.localFileRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let ext = (entry as NSString).pathExtension.lowercased()
                if installerExtensions.contains(ext) { continue }
                let path = root + "/" + entry
                guard matchesLocalName(entry, tokens: tokens) else { continue }
                guard Safety.checkLocalFile(path).ok else { continue }
                let size = size(of: path)
                if size == 0 { continue }
                results.append(ResidueItem(
                    path: path,
                    label: (root as NSString).lastPathComponent,
                    confidence: .medium,
                    size: size,
                    privileged: false,
                    local: true,
                    selected: false
                ))
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    /// 可执行文件名常常是英文（红果免费短剧 → hongguo-desktop-companion），能补上中文名匹配不到的目录
    static func executableName(_ appPath: String) -> String {
        let infoPath = appPath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: infoPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let exe = dict["CFBundleExecutable"] as? String,
              exe.lowercased() != "electron"
        else { return "" }
        return exe
    }

    static func matchesLocalName(_ entry: String, tokens: Set<String>) -> Bool {
        let lower = entry.lowercased()
        let parts = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens {
            if lower == token { return true }
            if lower.hasPrefix(token + ".") || lower.hasPrefix(token + " ")
                || lower.hasPrefix(token + "-") || lower.hasPrefix(token + "_") { return true }
            for part in parts {
                if part == token { return true }
                // lark → Larksuite / lark_notes；中文没有分词，前缀命中即可
                if part.hasPrefix(token) && part.count <= token.count + 8 { return true }
            }
        }
        return false
    }

    // MARK: - 辅助

    static func fill(_ pattern: String, _ ctx: [String: String]) -> String? {
        var result = pattern
        for (key, value) in ctx {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        if result.contains("{") || result.contains("}") { return nil }
        return (result as NSString).expandingTildeInPath
    }

    /// 候选条目：只确认存在，体积留到去重之后统一算
    struct Candidate {
        var path: String
        var label: String
        var confidence: Confidence
    }

    static func candidate(_ path: String, label: String, confidence: Confidence) -> Candidate? {
        let standardized = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: standardized)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: standardized)) != nil
        else { return nil }
        return Candidate(path: standardized, label: label, confidence: confidence)
    }

    static func makeItem(_ path: String, label: String, confidence: Confidence) -> ResidueItem? {
        guard let c = candidate(path, label: label, confidence: confidence) else { return nil }
        return ResidueItem(
            path: c.path,
            label: c.label,
            confidence: c.confidence,
            size: size(of: c.path),
            privileged: Safety.needsAdmin(c.path)
        )
    }

    /// 支持 `*` 的简易 glob：只在最后一级目录内枚举匹配。
    static func expandGlob(_ pattern: String) -> [String] {
        let ns = pattern as NSString
        let dir = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        guard name.contains("*") || name.contains("?") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { wildcardMatch(name, $0) }.map { dir + "/" + $0 }
    }

    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0, ti = 0
        var starIndex = -1
        var matchIndex = 0

        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func groupContainers(_ app: ManagedApp) -> [String] {
        let root = "\(home)/Library/Group Containers"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let bid = app.bundleID.lowercased()
        let token = app.name.lowercased().filter { $0.isLetter || $0.isNumber }
        var hits: [String] = []
        for entry in entries {
            let low = entry.lowercased()
            let flat = low.filter { $0.isLetter || $0.isNumber }
            var matched = false
            if !bid.isEmpty && low.hasPrefix(bid + ".") { matched = true }
            else if !token.isEmpty && token.count >= 4 && flat.contains(token) { matched = true }
            if matched { hits.append(root + "/" + entry) }
        }
        return hits
    }

    static func fuzzyDirs(_ app: ManagedApp) -> [String] {
        let token = app.name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard token.count >= 4 else { return [] }
        var hits: [String] = []
        for root in ["\(home)/Library/Application Support", "\(home)/Library/Caches"] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let flat = entry.lowercased().filter { $0.isLetter || $0.isNumber }
                guard flat.count >= 4 else { continue }
                if flat.hasPrefix(token) || token.hasPrefix(flat) {
                    hits.append(root + "/" + entry)
                }
            }
        }
        return hits
    }

    static func pkgID(for path: String) -> String? {
        // `pkgutil --file-info` 要起一个进程，40 ms 起步。
        // 绝大多数应用根本没有收据，而这个结果在一次会话里不会变，缓存住。
        pkgIDCacheLock.lock()
        if let hit = pkgIDCache[path] {
            pkgIDCacheLock.unlock()
            return hit == pkgIDNoReceipt ? nil : hit
        }
        pkgIDCacheLock.unlock()

        var found: String?
        if let output = run("/usr/sbin/pkgutil", ["--file-info", path]) {
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("pkgid:") {
                    let value = trimmed.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { found = value }
                    break
                }
            }
        }

        pkgIDCacheLock.lock()
        pkgIDCache[path] = found ?? pkgIDNoReceipt
        pkgIDCacheLock.unlock()
        return found
    }

    private static let pkgIDNoReceipt = "-"
    private static let pkgIDCacheLock = NSLock()
    nonisolated(unsafe) private static var pkgIDCache: [String: String] = [:]

    struct PkgResidues {
        var items: [Candidate]
        var notes: [String]
        /// 查到的收据 id，调用方复用它写提示，省一次 `pkgutil --file-info`
        var pkgID: String?
    }

    static func pkgResidues(_ app: ManagedApp) -> PkgResidues {
        guard let pkg = pkgID(for: app.path) else { return PkgResidues(items: [], notes: [], pkgID: nil) }
        guard let output = run("/usr/sbin/pkgutil", ["--files", pkg]) else {
            return PkgResidues(items: [], notes: [], pkgID: pkg)
        }

        var items: [Candidate] = []
        var notes: [String] = []
        for line in output.split(separator: "\n") {
            var path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path != "." else { continue }
            if !path.hasPrefix("/") { path = "/" + path }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if path == app.path || path.hasPrefix(app.path + "/") { continue }
            let check = Safety.check(path)
            if !check.ok {
                notes.append("安装包文件不在可操作范围（\(check.reason)）：\(path)")
                continue
            }
            if let item = candidate(path, label: "安装包文件", confidence: .high) {
                items.append(item)
            }
        }
        return PkgResidues(items: items, notes: notes, pkgID: pkg)
    }

    static func run(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 扫描计时（`--scan-timing <应用名>`）

    /// 把 `scan()` 拆成阶段逐个计时，并对比冷 / 热缓存。
    /// 排查「扫一个 20 KB 的应用为什么要好几秒」时用的。
    static func timingReport(_ query: String) {
        let all = discoverApps()
        guard let target = all.first(where: {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }) else {
            print("没找到匹配「\(query)」的应用。候选：")
            for a in all.prefix(20) { print("  \(a.name)  [\(a.path)]") }
            return
        }

        print("目标：\(target.name)")
        print("  路径：\(target.path)")
        print("  bundle id：\(target.bundleID.isEmpty ? "（无）" : target.bundleID)")

        // 阶段计时
        var phases: [(String, Double)] = []
        var clock = Date()
        func tick(_ label: String) {
            phases.append((label, Date().timeIntervalSince(clock)))
            clock = Date()
        }

        clock = Date()
        let rules = loadRules()
        tick("读取规则表（\(rules.templates.count) 模板 / \(rules.globs.count) 通配）")

        let ctx: [String: String] = [
            "name": target.name, "bundle_name": target.name, "bundle_id": target.bundleID
        ]
        var hit = 0
        for tpl in rules.templates {
            if tpl.path.contains("{bundle_id}") && target.bundleID.isEmpty { continue }
            guard let filled = fill(tpl.path, ctx) else { continue }
            if candidate(filled, label: tpl.label, confidence: .medium) != nil { hit += 1 }
        }
        tick("展开规则模板（命中 \(hit) 项）")

        var globHits = 0
        for glob in rules.globs {
            if glob.pattern.contains("{bundle_id}") && target.bundleID.isEmpty { continue }
            guard let filled = fill(glob.pattern, ctx) else { continue }
            for path in expandGlob(filled) {
                if candidate(path, label: glob.label, confidence: .medium) != nil { globHits += 1 }
            }
        }
        tick("展开通配规则（命中 \(globHits) 项）")

        let pkg = pkgResidues(target)
        tick("安装包收据（\(pkg.items.count) 个文件）")

        let local = localFiles(for: target)
        tick("本地文件（\(local.count) 项）")

        // 完整流程：冷缓存（清单就绪 + 体积全部算完）与热缓存
        clearSizeCache()
        var partialAt: Double = -1
        let t0 = Date()
        timingEnabled = true
        slowSizes = []
        _ = scan(target, includeLow: false) { _ in
            if partialAt < 0 { partialAt = Date().timeIntervalSince(t0) }
        }
        timingEnabled = false
        let cold = Date().timeIntervalSince(t0)

        let t1 = Date()
        _ = scan(target, includeLow: false)
        let warm = Date().timeIntervalSince(t1)

        print("\n阶段耗时：")
        for (label, dt) in phases {
            print(String(format: "  %6.0f ms  %@", dt * 1000, label))
        }
        print(String(format: "\n完整 scan()："))
        print(String(format: "  %6.0f ms  清单就绪（用户看到列表）", partialAt * 1000))
        print(String(format: "  %6.0f ms  冷缓存跑完（含算体积）", cold * 1000))
        print(String(format: "  %6.0f ms  热缓存再跑一遍", warm * 1000))

        if !slowSizes.isEmpty {
            print("\n最慢的体积计算（冷缓存）：")
            for item in slowSizes.sorted(by: { $0.seconds > $1.seconds }).prefix(6) {
                print(String(format: "  %6.0f ms  %5d 文件  %@", item.seconds * 1000, item.files, item.path))
            }
            print(String(format: "体积计算合计 %.0f ms，调用 %d 次",
                         slowSizes.reduce(0) { $0 + $1.seconds } * 1000, slowSizes.count))
        }
    }
}
