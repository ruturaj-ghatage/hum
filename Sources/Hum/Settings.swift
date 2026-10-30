import AppKit

/// Feature switches, shown in the notch's settings panel and the menu bar. Persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var reactToAudio: Bool { didSet { save("reactToAudio", reactToAudio) } }
    @Published var ambientGlow: Bool { didSet { save("ambientGlow", ambientGlow) } }
    @Published var peekOnTrackChange: Bool { didSet { save("peekOnTrackChange", peekOnTrackChange) } }
    @Published var focusNudges: Bool { didSet { save("focusNudges", focusNudges) } }
    @Published var workStatus: Bool { didSet { save("workStatus", workStatus) } }
    @Published var notifications: Bool { didSet { save("notifications", notifications) } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["reactToAudio": true, "ambientGlow": true, "peekOnTrackChange": true,
                              "focusNudges": true, "workStatus": true, "notifications": true])
        reactToAudio = d.bool(forKey: "reactToAudio")
        ambientGlow = d.bool(forKey: "ambientGlow")
        peekOnTrackChange = d.bool(forKey: "peekOnTrackChange")
        focusNudges = d.bool(forKey: "focusNudges")
        workStatus = d.bool(forKey: "workStatus")
        notifications = d.bool(forKey: "notifications")
    }

    private func save(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key) }
}

enum AppleScript {
    /// Runs a script synchronously. Call off the main thread when it may be slow.
    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Hum AppleScript error: \(error)") }
        return error == nil ? result : nil
    }
}

func clock(_ seconds: TimeInterval) -> String {
    let s = Int(max(seconds, 0).rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}
