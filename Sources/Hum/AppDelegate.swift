import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let player = NowPlaying()
    let focus = FocusGuardian()
    let tracker = ActivityTracker()
    let levels = AudioLevels()
    let settings = Settings.shared
    let camera = CameraSensor()
    /// Music we paused because you walked away, so we only resume what we stopped.
    private var pausedForAway = false
    private var notch: NotchController!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController(player: player, focus: focus, tracker: tracker, settings: settings, levels: levels,
                                camera: camera)
        wireEvents()
        setupStatusItem()
        player.start()
    }

    private func wireEvents() {
        focus.onStart = { [weak self] minutes in
            self?.notch.show(.init(symbol: "hourglass", color: .systemMint, title: "Focus on · \(minutes) min",
                                   subtitle: "I'll nudge you if you wander off"))
        }
        focus.onDistracted = { [weak self] remaining in
            guard self?.settings.focusNudges == true else { return }
            self?.notch.shake()
            self?.notch.show(.init(symbol: "eyes", color: .systemOrange, title: "Hey — back to work",
                                   subtitle: "\(clock(remaining)) left in this focus"))
        }
        focus.onFinish = { [weak self] slips in
            self?.notch.ripple(.systemMint)
            self?.notch.show(.init(symbol: "checkmark.seal.fill", color: .systemMint, title: "Focus done — nice!",
                                   subtitle: slips == 0 ? "Zero slips. Take a 5 min break."
                                                        : "\(slips) slip\(slips == 1 ? "" : "s"). Take a 5 min break."))
        }

        tracker.onFinish = { [weak self] job, ok, duration in
            guard self?.settings.workStatus == true else { return }
            self?.notch.ripple(ok ? .systemGreen : .systemRed)
            // Claude finishes lots of quick turns; only announce the ones worth looking up for.
            guard job.kind == .task || duration >= 15 else { return }
            let title: String
            switch (job.kind, ok) {
            case (.claude, _): title = "Claude finished · \(job.label)"
            case (.task, true): title = "Done · \(job.label)"
            case (.task, false): title = "Failed · \(job.label)"
            }
            self?.notch.show(.init(symbol: ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                                   color: ok ? .systemGreen : .systemRed, title: title,
                                   subtitle: "took \(clock(duration))"))
        }
        tracker.onAttention = { [weak self] job in
            guard self?.settings.workStatus == true else { return }
            self?.notch.ripple(.systemBlue)
            self?.notch.show(.init(symbol: "hand.raised.fill", color: .systemBlue,
                                   title: "Claude needs you", subtitle: job.label))
        }

        // Only listen to system audio while music is actually playing.
        Publishers.CombineLatest(player.$isPlaying, settings.$reactToAudio)
            .receive(on: RunLoop.main)
            .sink { [weak self] playing, react in
                if playing && react { self?.levels.start() } else { self?.levels.stop() }
            }
            .store(in: &cancellables)

        wireCamera()
    }

    // MARK: Camera

    private func wireCamera() {
        Publishers.CombineLatest4(settings.$cameraEnabled, settings.$lookToWake, settings.$airGestures, settings.$walkAwayPause)
            .receive(on: RunLoop.main)
            .sink { [weak self] on, look, gestures, away in
                self?.camera.configure(enabled: on, look: look, gestures: gestures, away: away)
            }
            .store(in: &cancellables)

        camera.$looking
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.notch.setLooking($0) }
            .store(in: &cancellables)

        camera.onPrompt = { [weak self] symbol, title, subtitle, seconds in
            self?.notch.show(.init(symbol: symbol, color: .systemTeal, title: title, subtitle: subtitle, duration: seconds))
        }

        camera.onGesture = { [weak self] gesture in
            guard let self, self.player.track != nil else { return }
            let tint = self.player.tint
            switch gesture {
            case .playPause:
                self.player.playPause()
                let playing = self.player.isPlaying
                self.notch.show(.init(symbol: playing ? "play.fill" : "pause.fill", color: tint,
                                      title: playing ? "Playing" : "Paused", subtitle: "✋ open palm", duration: 1.5))
            case .next:
                self.player.next()
                self.notch.show(.init(symbol: "forward.fill", color: tint, title: "Next track", subtitle: "👉 swipe", duration: 1.5))
            case .previous:
                self.player.previous()
                self.notch.show(.init(symbol: "backward.fill", color: tint, title: "Previous track", subtitle: "👈 swipe", duration: 1.5))
            }
            self.notch.ripple(tint)
        }

        camera.onAway = { [weak self] in
            guard let self else { return }
            if self.player.isPlaying {
                self.player.playPause()
                self.pausedForAway = true
            }
            self.focus.pause()
        }

        camera.onReturn = { [weak self] gone in
            guard let self else { return }
            var bits = ["away \(clock(gone))"]
            if self.pausedForAway {
                self.pausedForAway = false
                if !self.player.isPlaying {
                    self.player.playPause()
                    bits.append("music resumed")
                }
            }
            if self.focus.isPaused {
                self.focus.resume()
                bits.append("focus resumed")
            }
            guard bits.count > 1 || gone > 60 else { return }
            self.notch.show(.init(symbol: "hand.wave.fill", color: .systemYellow, title: "Welcome back",
                                  subtitle: bits.joined(separator: " · ")))
        }

        // Never watch while the screen is asleep or locked.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.camera.setSuspended(true)
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.camera.setSuspended(false)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.camera.setSuspended(true)
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.camera.setSuspended(false)
        }
    }

    // MARK: hum:// URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    /// hum://notify?title=&body=&symbol=&color=
    /// hum://claude?event=start|stop|attention|end&session=&project=
    /// hum://task?event=start|done&id=&label=&ok=1|0
    /// hum://focus?minutes=25  ·  hum://focus?action=stop
    private func handle(_ url: URL) {
        guard url.scheme == "hum" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        switch url.host {
        case "notify":
            guard settings.notifications else { return }
            notch.show(.init(symbol: q["symbol"] ?? "bell.fill", color: Self.color(q["color"]),
                             title: q["title"] ?? "Hum", subtitle: q["body"] ?? ""))
        case "claude":
            tracker.claude(event: q["event"] ?? "", session: q["session"] ?? "", project: q["project"] ?? "")
        case "task":
            tracker.task(event: q["event"] ?? "", id: q["id"] ?? "", label: q["label"] ?? "", ok: q["ok"] != "0")
        case "settings":
            notch.openSettings(tab: q["tab"] == "camera" ? 1 : 0)
        case "focus":
            if let m = Int(q["minutes"] ?? "") { focus.start(minutes: m) }
            else if q["action"] == "stop" { focus.stop() }
        default:
            break
        }
    }

    private static func color(_ name: String?) -> NSColor {
        switch name?.lowercased() {
        case "green": return .systemGreen
        case "red": return .systemRed
        case "blue": return .systemBlue
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "mint": return .systemMint
        case "yellow": return .systemYellow
        default: return .systemPink
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Hum")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if focus.isActive {
            let status = NSMenuItem(title: "Focusing · \(clock(focus.remaining())) left", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if focus.isPaused {
                menu.addItem(ActionItem("Resume Focus") { [weak self] in self?.focus.resume() })
            } else {
                menu.addItem(ActionItem("Add 5 Minutes") { [weak self] in self?.focus.extend(minutes: 5) })
            }
            menu.addItem(ActionItem("Stop Focus") { [weak self] in self?.focus.stop() })
        } else {
            for m in [25, 50, 90] {
                menu.addItem(ActionItem("Focus for \(m) min") { [weak self] in self?.focus.start(minutes: m) })
            }
        }

        menu.addItem(.separator())
        let toggles: [(String, ReferenceWritableKeyPath<Settings, Bool>)] = [
            ("React to Audio", \.reactToAudio), ("Ambient Glow", \.ambientGlow),
            ("Peek on New Song", \.peekOnTrackChange), ("Focus Nudges", \.focusNudges),
            ("Claude & Build Status", \.workStatus), ("Notifications", \.notifications),
        ]
        for (title, key) in toggles {
            menu.addItem(ActionItem(title, on: settings[keyPath: key]) { [weak self] in self?.settings[keyPath: key].toggle() })
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Camera", on: settings.cameraEnabled) { [weak self] in self?.settings.cameraEnabled.toggle() })
        let cameraToggles: [(String, ReferenceWritableKeyPath<Settings, Bool>)] = [
            ("    Look to Wake", \.lookToWake), ("    Air Gestures", \.airGestures), ("    Walk-Away Pause", \.walkAwayPause),
        ]
        for (title, key) in cameraToggles {
            let item = ActionItem(title, on: settings[keyPath: key]) { [weak self] in self?.settings[keyPath: key].toggle() }
            item.isEnabled = settings.cameraEnabled
            menu.addItem(item)
        }
        menu.addItem(ActionItem(camera.calibrated ? "    Recalibrate Gaze…" : "    Calibrate Gaze…") { [weak self] in
            self?.settings.cameraEnabled = true
            self?.camera.calibrate()
        })

        menu.addItem(.separator())
        menu.addItem(ActionItem("Open Settings in Notch") { [weak self] in self?.notch.openSettings() })

        menu.addItem(.separator())
        menu.addItem(ActionItem("Launch at Login", on: SMAppService.mainApp.status == .enabled) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {
                NSLog("Hum: launch at login failed: \(error)")
            }
        })
        menu.addItem(NSMenuItem(title: "Quit Hum", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let on { state = on ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
