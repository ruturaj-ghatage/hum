import AppKit

/// A Pomodoro-style focus timer that notices when you drift to distracting apps or sites.
final class FocusGuardian: ObservableObject {
    @Published private(set) var endsAt: Date?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var slips = 0
    @Published private(set) var pausedAt: Date?

    var onStart: ((Int) -> Void)?
    var onDistracted: ((TimeInterval) -> Void)?
    var onFinish: ((Int) -> Void)?

    var isActive: Bool { endsAt != nil }
    var isPaused: Bool { pausedAt != nil }

    private var timer: Timer?
    private var lastNudge = Date.distantPast
    private let scriptQueue = DispatchQueue(label: "hum.focus")

    static let distractingApps: Set<String> = [
        "com.hnc.Discord", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "com.valvesoftware.steam", "com.apple.TV", "com.netflix.Netflix",
    ]
    static let distractingSites = [
        "twitter.com", "x.com", "youtube.com", "reddit.com", "instagram.com", "facebook.com",
        "tiktok.com", "netflix.com", "twitch.tv", "news.ycombinator.com",
    ]
    /// Browser bundle id → AppleScript application name.
    static let browsers = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    func remaining(at date: Date = Date()) -> TimeInterval {
        guard let endsAt else { return 0 }
        return max(endsAt.timeIntervalSince(pausedAt ?? date), 0)
    }

    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }

    func start(minutes: Int) {
        duration = TimeInterval(minutes * 60)
        endsAt = Date().addingTimeInterval(duration)
        slips = 0
        pausedAt = nil
        lastNudge = Date() // grace period right after starting
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        onStart?(minutes)
    }

    func extend(minutes: Int) {
        guard let endsAt else { return }
        self.endsAt = endsAt.addingTimeInterval(TimeInterval(minutes * 60))
        duration += TimeInterval(minutes * 60)
    }

    /// Freezes the countdown (e.g. while you're away from the Mac).
    func pause() {
        guard isActive, pausedAt == nil else { return }
        pausedAt = Date()
    }

    func resume() {
        guard let p = pausedAt, let endsAt else { return }
        self.endsAt = endsAt.addingTimeInterval(Date().timeIntervalSince(p))
        pausedAt = nil
        lastNudge = Date()
    }

    func stop() {
        endsAt = nil
        pausedAt = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let endsAt, pausedAt == nil else { return }
        if Date() >= endsAt {
            let s = slips
            stop()
            onFinish?(s)
            return
        }
        guard Date().timeIntervalSince(lastNudge) > 20,
              let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }

        if Self.distractingApps.contains(id) { nudge(); return }
        guard let name = Self.browsers[id] else { return }
        let script = id == "com.apple.Safari"
            ? "tell application \"Safari\" to return URL of front document"
            : "tell application \"\(name)\" to return URL of active tab of front window"
        scriptQueue.async {
            let host = URL(string: AppleScript.run(script)?.stringValue ?? "")?.host?.lowercased() ?? ""
            let bad = Self.distractingSites.contains { host == $0 || host.hasSuffix("." + $0) }
            if bad { DispatchQueue.main.async { self.nudge() } }
        }
    }

    private func nudge() {
        guard isActive, Date().timeIntervalSince(lastNudge) > 20 else { return }
        lastNudge = Date()
        slips += 1
        onDistracted?(remaining())
    }
}
