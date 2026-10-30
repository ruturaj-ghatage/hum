import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Let the panel sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    static func make(levelOffset: Int) -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + levelOffset)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        return panel
    }
}

/// Layout state shared by the controller (hit testing) and the SwiftUI view (drawing).
final class NotchModel: ObservableObject {
    enum Mode: Equatable { case idle, compact, expanded, toast }
    /// What the two sides of the notch show in compact mode, by priority.
    enum Wings: Equatable { case none, music, focus, work }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var symbol: String
        var color: NSColor
        var title: String
        var subtitle: String = ""
        var duration: TimeInterval = 3.8
    }

    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        var color: NSColor
    }

    @Published var hovering = false
    @Published var peeking = false
    @Published var dragging = false
    @Published var dismissed = false
    @Published var showSettings = false
    @Published var settingsTab = 0 // 0 general, 1 camera
    @Published var looking = false
    @Published var toast: Toast?
    @Published var ripple: Ripple?
    @Published var shakes: CGFloat = 0
    @Published var notchSize = CGSize(width: 185, height: 32)
    @Published var screenFrame = CGRect.zero

    let earRadius: CGFloat = 6
    let player: NowPlaying
    let focus: FocusGuardian
    let tracker: ActivityTracker
    let settings: Settings

    init(player: NowPlaying, focus: FocusGuardian, tracker: ActivityTracker, settings: Settings) {
        self.player = player
        self.focus = focus
        self.tracker = tracker
        self.settings = settings
    }

    var canExpand: Bool { player.track != nil || focus.isActive || showSettings }

    var wings: Wings {
        if player.isPlaying && player.track != nil { return .music }
        if focus.isActive { return .focus }
        if tracker.isBusy && settings.workStatus { return .work }
        return .none
    }

    var mode: Mode {
        if (hovering || peeking || looking) && canExpand && !dismissed { return .expanded }
        if toast != nil { return .toast }
        return wings == .none ? .idle : .compact
    }

    /// Size of the black body, not counting the little top "ears".
    func size(for mode: Mode) -> CGSize {
        let n = notchSize
        switch mode {
        case .idle: return CGSize(width: n.width - earRadius * 2, height: n.height)
        case .compact: return CGSize(width: n.width + (n.height + 8) * 2, height: n.height)
        case .expanded:
            if showSettings { return CGSize(width: max(n.width + 220, 420), height: n.height + 142) }
            return player.track != nil
                ? CGSize(width: max(n.width + 220, 420), height: n.height + 134)
                : CGSize(width: max(n.width + 160, 380), height: n.height + 92)
        case .toast: return CGSize(width: max(n.width + 150, 360), height: n.height + 58)
        }
    }
}

final class NotchController {
    let model: NotchModel
    private let player: NowPlaying
    private let panel = NotchPanel.make(levelOffset: 3)
    private let glowPanel = NotchPanel.make(levelOffset: 2)
    private var screen: NSScreen = NSScreen.main!
    private var mouseTimer: Timer?
    private var peekWork: DispatchWorkItem?
    private var toastQueue: [NotchModel.Toast] = []
    private var cancellables = Set<AnyCancellable>()

    init(player: NowPlaying, focus: FocusGuardian, tracker: ActivityTracker, settings: Settings, levels: AudioLevels,
         camera: CameraSensor) {
        self.player = player
        model = NotchModel(player: player, focus: focus, tracker: tracker, settings: settings)

        let host = NSHostingView(rootView: NotchView(model: model, player: player, focus: focus, tracker: tracker,
                                                     settings: settings, levels: levels, camera: camera))
        host.sizingOptions = []
        panel.contentView = host

        let glow = NSHostingView(rootView: AmbientGlowView(player: player, settings: settings, levels: levels))
        glow.sizingOptions = []
        glowPanel.contentView = glow

        layout()
        glowPanel.orderFrontRegardless()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }

        player.trackChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.peek() }
            .store(in: &cancellables)

        // Polling the cursor is cheap and works whether or not Hum is active.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            self?.trackMouse()
        }
    }

    // MARK: Effects

    func show(_ toast: NotchModel.Toast) {
        toastQueue.append(toast)
        if model.toast == nil { presentNextToast() }
    }

    func ripple(_ color: NSColor) {
        let r = NotchModel.Ripple(color: color)
        model.ripple = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.model.ripple?.id == r.id { self?.model.ripple = nil }
        }
    }

    func shake() {
        withAnimation(.linear(duration: 0.6)) { model.shakes += 1 }
    }

    private func presentNextToast() {
        guard !toastQueue.isEmpty else { return }
        let t = toastQueue.removeFirst()
        model.toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + t.duration) { [weak self] in
            guard let self, self.model.toast?.id == t.id else { return }
            self.model.toast = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.presentNextToast() }
        }
    }

    // MARK: Layout & hover

    /// Finds the built-in (notched) display and pins the panels to it.
    private func layout() {
        screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchSize = CGSize(width: f.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            // No notch: draw a fake one the height of the menu bar.
            model.notchSize = CGSize(width: 185, height: max(f.maxY - screen.visibleFrame.maxY, 24))
        }
        model.screenFrame = f
        let w = max(model.notchSize.width + 220, 420) + model.earRadius * 2 + 140
        let h = model.notchSize.height + 134 + 140 // room for pull-down, glow and ripples
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
        glowPanel.setFrame(f, display: true)
    }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        let mode = model.mode

        let size = model.size(for: mode)
        let f = screen.frame
        let pad: CGFloat = mode == .expanded ? 8 : 2
        let hit = NSRect(x: f.midX - size.width / 2 - model.earRadius - pad, y: f.maxY - size.height - pad,
                         width: size.width + model.earRadius * 2 + pad * 2, height: size.height + pad)
        let inside = model.dragging || (model.canExpand && hit.contains(p))

        if inside != model.hovering {
            model.hovering = inside
            panel.ignoresMouseEvents = !inside
            if inside {
                peekWork?.cancel()
                model.peeking = false
                player.resync()
            } else {
                model.dismissed = false
                model.showSettings = false
            }
        }
    }

    /// Look to wake: open while the camera says you're looking at the notch.
    func setLooking(_ looking: Bool) {
        guard model.looking != looking else { return }
        model.looking = looking
        if looking { player.resync() }
    }

    /// Opens the notch on the settings panel for a few seconds (or until the cursor leaves it).
    func openSettings(tab: Int = 0) {
        peekWork?.cancel()
        model.settingsTab = tab
        model.showSettings = true
        model.peeking = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.hovering else { return }
            self.model.peeking = false
            self.model.showSettings = false
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func peek() {
        guard !model.hovering, model.settings.peekOnTrackChange else { return }
        peekWork?.cancel()
        model.peeking = true
        let work = DispatchWorkItem { [weak self] in self?.model.peeking = false }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
