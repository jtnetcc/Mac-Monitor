import AppKit

// MARK: - 告警提示音
//
// 触发点只有一个：`MetricsStore.fire()`。那里已经是「新告警」的唯一出口，
// 自带冷却期（`thresholds.cooldown`），所以不用担心同一条告警反复响。
//
// 两级用两个音色：警告用清亮的 Glass，危险用低沉的 Basso——不看屏幕也能听出严重程度。
// 关掉之后完全静音，不会退回系统 beep。

enum SoundAlert {
    private static let enabledKey = "soundAlertEnabled"

    /// 默认开。用户显式关过才读得到 false
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 预加载过的 NSSound，避免每次告警现读 aiff
    private static var cache: [String: NSSound] = [:]

    private static func name(for level: AlertEvent.Level) -> String {
        level == .danger ? "Basso" : "Glass"
    }

    /// 声音自己的冷却期。面板上的告警条按 `thresholds.cooldown`（10 分钟）刷新，
    /// 但同一条告警如果一直成立，一天会响几十次——声音比视觉烦得多，所以单独放宽到 30 分钟
    private static let soundCooldown: TimeInterval = 1800
    private static var lastSound: [String: TimeInterval] = [:]

    /// 告警时响一声
    static func play(_ level: AlertEvent.Level, key: String, now: TimeInterval) {
        guard isEnabled else { return }
        if let last = lastSound[key], now - last < soundCooldown { return }
        lastSound[key] = now
        play(named: name(for: level))
    }

    /// 试听。打开开关时响一下，让人知道它到底响什么
    static func preview(_ level: AlertEvent.Level = .warn) {
        play(named: name(for: level))
    }

    private static func play(named soundName: String) {
        let work = {
            let sound: NSSound
            if let cached = cache[soundName] {
                sound = cached
            } else if let loaded = NSSound(named: NSSound.Name(soundName)) {
                cache[soundName] = loaded
                sound = loaded
            } else {
                // 系统音效被删了也不至于没声音
                NSSound.beep()
                return
            }
            // 上一条还没播完就先掐掉，连续告警不会叠成一团
            if sound.isPlaying { sound.stop() }
            sound.play()
        }

        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
