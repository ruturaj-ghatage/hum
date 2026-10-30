import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Let the panel sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Layout state shared by the controller (hit testing) and the SwiftUI view (drawing).
final class NotchModel: ObservableObject {
    enum Mode { case idle, compact, expanded }

    @Published var hovering = false
    @Published var peeking = false
    @Published var notchSize = CGSize(width: 185, height: 32)

    let earRadius: CGFloat = 6

    func mode(for player: NowPlaying) -> Mode {
        guard player.track != nil else { return .idle }
        if hovering || peeking { return .expanded }
        return player.isPlaying ? .compact : .idle
    }

    /// Size of the black body, not counting the little top "ears".
    func size(for mode: Mode) -> CGSize {
        let n = notchSize
        switch mode {
        case .idle: return CGSize(width: n.width - earRadius * 2, height: n.height)
        case .compact: return CGSize(width: n.width + (n.height + 8) * 2, height: n.height)
        case .expanded: return CGSize(width: max(n.width + 220, 420), height: n.height + 134)
        }
    }
}

final class NotchController {
    private let player: NowPlaying
    private let model = NotchModel()
    private let panel: NotchPanel
    private var screen: NSScreen = NSScreen.main!
    private var mouseTimer: Timer?
    private var peekWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(player: NowPlaying) {
        self.player = player
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: NotchView(player: player, model: model))
        host.sizingOptions = []
        panel.contentView = host

        layout()
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

    /// Finds the built-in (notched) display and pins the panel to its top center.
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
        let big = model.size(for: .expanded)
        let w = big.width + model.earRadius * 2 + 60
        let h = big.height + 40
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h), display: true)
    }

    private func trackMouse() {
        let mode = model.mode(for: player)
        // In idle, hovering the bare notch only matters if there's something paused to show.
        let size = model.size(for: mode == .idle && player.track == nil ? .idle : mode)
        let f = screen.frame
        let pad: CGFloat = mode == .expanded ? 8 : 2
        let hit = NSRect(x: f.midX - size.width / 2 - model.earRadius - pad, y: f.maxY - size.height - pad,
                         width: size.width + model.earRadius * 2 + pad * 2, height: size.height + pad)
        let inside = player.track != nil && hit.contains(NSEvent.mouseLocation)

        if inside != model.hovering {
            model.hovering = inside
            panel.ignoresMouseEvents = !inside
            if inside {
                peekWork?.cancel()
                model.peeking = false
                player.resync()
            }
        }
    }

    private func peek() {
        guard !model.hovering else { return }
        peekWork?.cancel()
        model.peeking = true
        let work = DispatchWorkItem { [weak self] in self?.model.peeking = false }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
