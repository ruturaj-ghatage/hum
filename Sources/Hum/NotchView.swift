import SwiftUI

/// Black body with rounded bottom corners and small concave "ears" at the top,
/// like the hardware notch melting into the menu bar.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let br = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + br, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - br), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var player: NowPlaying
    @ObservedObject var focus: FocusGuardian
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var settings: Settings
    let levels: AudioLevels
    @ObservedObject var camera: CameraSensor

    /// Physics: how far the expanded notch is pulled down / swiped sideways.
    @State private var pull: CGFloat = 0
    @State private var swipe: CGFloat = 0

    private var n: CGSize { model.notchSize }
    private var tint: Color { Color(nsColor: player.tint) }

    var body: some View {
        let mode = model.mode
        let base = model.size(for: mode)
        let size = CGSize(width: base.width, height: base.height + (mode == .expanded ? pull : 0))
        let shape = NotchShape(bottomRadius: mode == .expanded || mode == .toast ? 24 : 10, ear: model.earRadius)

        VStack(spacing: 0) {
            BeatPulse(levels: levels, active: mode == .compact && model.wings == .music) {
                content(mode)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .overlay(alignment: .topTrailing) { gear(mode) }
                    .overlay(alignment: .bottom) { focusLine(mode) }
                    .clipped()
                    .padding(.horizontal, model.earRadius)
                    .background(Color.black)
                    .clipShape(shape)
                    .background { StatusGlow(color: glowColor, shape: shape) }
                    .overlay { rippleView(shape) }
            }
            .modifier(Shake(animatableData: model.shakes))
            .shadow(color: .black.opacity(mode == .expanded || mode == .toast ? 0.45 : 0), radius: 14, y: 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mode)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.wings)
        .animation(.easeInOut(duration: 0.4), value: player.tint)
        .preferredColorScheme(.dark)
    }

    private var glowColor: Color? {
        guard settings.workStatus else { return nil }
        if tracker.isWaiting { return .blue }
        if tracker.isBusy { return .orange }
        return nil
    }

    @ViewBuilder private func content(_ mode: NotchModel.Mode) -> some View {
        ZStack(alignment: .top) {
            switch mode {
            case .idle:
                EmptyView()
            case .compact:
                compact.transition(.opacity)
            case .expanded:
                Group {
                    if model.showSettings { settingsPanel }
                    else if player.track != nil { playerView }
                    else { focusPanel }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            case .toast:
                toastView.transition(.opacity.combined(with: .offset(y: -12)))
            }
        }
    }

    // MARK: Compact wings

    private var compact: some View {
        let h = n.height
        return HStack(spacing: 0) {
            leftWing.frame(width: h - 10, height: h - 10)
            Spacer(minLength: n.width)
            rightWing.frame(width: h, height: h - 10)
        }
        .padding(.horizontal, 8)
        .frame(height: h)
    }

    @ViewBuilder private var leftWing: some View {
        switch model.wings {
        case .music:
            Artwork(image: player.artwork, size: n.height - 10, radius: 5)
        case .focus:
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mint)
                .symbolEffect(.pulse)
        case .work:
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tracker.isWaiting ? Color.blue : Color.orange)
                .symbolEffect(.pulse)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch model.wings {
        case .music:
            Bars(levels: levels, playing: player.isPlaying, color: tint, height: 12)
        case .focus:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                wingText(clock(focus.remaining(at: ctx.date)), color: .mint)
            }
        case .work:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                wingText(clock(ctx.date.timeIntervalSince(tracker.oldestStart ?? ctx.date)),
                         color: tracker.isWaiting ? .blue : .orange)
            }
        case .none:
            EmptyView()
        }
    }

    private func wingText(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// Thin hourglass bar along the bottom edge while focusing.
    @ViewBuilder private func focusLine(_ mode: NotchModel.Mode) -> some View {
        if focus.isActive && mode == .compact {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.mint)
                        .frame(width: max(geo.size.width * focus.progress(at: ctx.date), 2), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder private func rippleView(_ shape: NotchShape) -> some View {
        if let r = model.ripple {
            RippleView(color: Color(nsColor: r.color), shape: shape)
                .id(r.id)
                .allowsHitTesting(false)
        }
    }

    // MARK: Expanded player (with fling physics)

    private var playerView: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: n.height - 4)

            HStack(spacing: 12) {
                Button(action: player.openPlayer) {
                    Artwork(image: player.artwork, size: 56, radius: 10)
                }
                .buttonStyle(.plain)
                .help("Open \(player.source.rawValue)")

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.track?.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text([player.track?.artist, player.track?.album]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Bars(levels: levels, playing: player.isPlaying, color: tint, height: 16)
            }

            ProgressBar(player: player, tint: tint)

            HStack(spacing: 34) {
                ControlButton(symbol: "backward.fill", size: 15, action: player.previous)
                ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 20, action: player.playPause)
                ControlButton(symbol: "forward.fill", size: 15, action: player.next)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .offset(x: swipe)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    model.dragging = true
                    swipe = v.translation.width * 0.6
                    pull = v.translation.height > 0 ? pow(v.translation.height, 0.8) : 0
                }
                .onEnded { v in
                    model.dragging = false
                    let t = v.predictedEndTranslation
                    if t.width < -140 { player.next() }
                    else if t.width > 140 { player.previous() }
                    else if t.height < -50 { model.dismissed = true }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) {
                        swipe = 0
                        pull = 0
                    }
                }
        )
    }

    // MARK: Expanded focus panel

    private var focusPanel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: focus.progress(at: ctx.date))
                        .stroke(Color.mint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "hourglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.mint)
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 1) {
                    Text("FOCUS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.5))
                    Text(clock(focus.remaining(at: ctx.date)))
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text(focus.isPaused ? "Paused — you stepped away"
                         : focus.slips == 0 ? "No slips yet" : "\(focus.slips) slip\(focus.slips == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                VStack(spacing: 8) {
                    if focus.isPaused {
                        PillButton(title: "Resume") { focus.resume() }
                    } else {
                        PillButton(title: "+5 min") { focus.extend(minutes: 5) }
                    }
                    PillButton(title: "Stop") { focus.stop() }
                }
            }
            .padding(.top, n.height + 8)
            .padding(.horizontal, 20)
        }
    }

    // MARK: Settings

    @ViewBuilder private func gear(_ mode: NotchModel.Mode) -> some View {
        if mode == .expanded {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.showSettings.toggle() }
            } label: {
                Image(systemName: model.showSettings ? "xmark" : "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.showSettings ? "Close settings" : "Settings")
            .padding(.top, 4)
            .padding(.trailing, 12)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                tabButton("GENERAL", tab: 0)
                tabButton("CAMERA", tab: 1)
            }
            if model.settingsTab == 0 { generalSettings } else { cameraSettings }
        }
        .padding(.top, n.height + 2)
        .padding(.horizontal, 20)
    }

    private func tabButton(_ title: String, tab: Int) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { model.settingsTab = tab } } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(.white.opacity(model.settingsTab == tab ? 0.95 : 0.4))
                .padding(.vertical, 2)
                .overlay(alignment: .bottom) {
                    if model.settingsTab == tab { Capsule().fill(.white).frame(height: 2).offset(y: 4) }
                }
        }
        .buttonStyle(.plain)
    }

    private var generalSettings: some View {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    SettingPill(symbol: "waveform", title: "React to audio", isOn: $settings.reactToAudio)
                    SettingPill(symbol: "sun.max.fill", title: "Ambient glow", isOn: $settings.ambientGlow)
                }
                GridRow {
                    SettingPill(symbol: "arrow.down.circle.fill", title: "Peek on new song", isOn: $settings.peekOnTrackChange)
                    SettingPill(symbol: "eyes", title: "Focus nudges", isOn: $settings.focusNudges)
                }
                GridRow {
                    SettingPill(symbol: "sparkle", title: "Claude & builds", isOn: $settings.workStatus)
                    SettingPill(symbol: "bell.badge.fill", title: "Notifications", isOn: $settings.notifications)
                }
            }
    }

    private var cameraSettings: some View {
        let on = settings.cameraEnabled
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                SettingPill(symbol: "camera.fill", title: "Camera", isOn: $settings.cameraEnabled)
                ActionPill(symbol: camera.calibrating ? "scope" : "viewfinder",
                           title: camera.calibrating ? "Calibrating…" : camera.calibrated ? "Recalibrate gaze" : "Calibrate gaze") {
                    camera.calibrate()
                }
            }
            GridRow {
                SettingPill(symbol: "eye.fill", title: camera.calibrated ? "Look to wake" : "Look to wake ⓘ", isOn: $settings.lookToWake)
                    .disabled(!on).opacity(on ? 1 : 0.4)
                    .help(camera.calibrated ? "Glance up at the notch to open it" : "Calibrate gaze first")
                SettingPill(symbol: "hand.raised.fill", title: "Air gestures", isOn: $settings.airGestures)
                    .disabled(!on).opacity(on ? 1 : 0.4)
                    .help("Open palm: play/pause · swipe: next/previous")
            }
            GridRow {
                SettingPill(symbol: "figure.walk", title: "Walk-away pause", isOn: $settings.walkAwayPause)
                    .disabled(!on).opacity(on ? 1 : 0.4)
                    .help("Pause music and focus when you leave")
                cameraStatus
            }
        }
    }

    private var cameraStatus: some View {
        let (text, color): (String, Color) = switch camera.status {
        case .off: ("Camera off", .white.opacity(0.4))
        case .denied: ("No camera access", .red)
        case .noFace: ("Can't see you", .orange)
        case .watching: (camera.looking ? "Looking at notch" : "Watching", .green)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30)
    }

    // MARK: Toast

    @ViewBuilder private var toastView: some View {
        if let t = model.toast {
            let color = Color(nsColor: t.color)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.18))
                    Image(systemName: t.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if !t.subtitle.isEmpty {
                        Text(t.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, n.height + 6)
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - Effects

/// Bulges the notch downward with the bass.
struct BeatPulse<Content: View>: View {
    @ObservedObject var levels: AudioLevels
    let active: Bool
    let content: Content

    init(levels: AudioLevels, active: Bool, @ViewBuilder content: () -> Content) {
        self.levels = levels
        self.active = active
        self.content = content()
    }

    var body: some View {
        let b = active && levels.hasSignal ? levels.bass : 0
        content.scaleEffect(x: 1 + b * 0.025, y: 1 + b * 0.16, anchor: .top)
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// Breathing colored halo around the notch (Claude/build busy).
struct StatusGlow: View {
    let color: Color?
    let shape: NotchShape
    @State private var breathe = false

    var body: some View {
        if let color {
            shape
                .stroke(color, lineWidth: 3)
                .shadow(color: color, radius: 3)
                .shadow(color: color, radius: 10)
                .shadow(color: color.opacity(0.6), radius: 18)
                .opacity(breathe ? 1 : 0.4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
                }
        }
    }
}

/// A notch-shaped ring that expands and fades (done / failed / needs you).
struct RippleView: View {
    let color: Color
    let shape: NotchShape
    @State private var go = false

    var body: some View {
        shape
            .stroke(color, lineWidth: 3)
            .shadow(color: color, radius: 6)
            .scaleEffect(go ? 1.45 : 1, anchor: .top)
            .opacity(go ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1.0)) { go = true } }
    }
}

/// Faint light around the screen edges in the album's color, breathing with the bass.
struct AmbientGlowView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var settings: Settings
    @ObservedObject var levels: AudioLevels

    var body: some View {
        let on = settings.ambientGlow && player.isPlaying && player.track != nil
        let c = Color(nsColor: player.tint)
        let w: CGFloat = 70
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [c, .clear], startPoint: .top, endPoint: .bottom).frame(height: w)
                Spacer()
                LinearGradient(colors: [.clear, c], startPoint: .top, endPoint: .bottom).frame(height: w)
            }
            HStack(spacing: 0) {
                LinearGradient(colors: [c, .clear], startPoint: .leading, endPoint: .trailing).frame(width: w)
                Spacer()
                LinearGradient(colors: [.clear, c], startPoint: .leading, endPoint: .trailing).frame(width: w)
            }
        }
        .opacity(on ? 0.1 + Double(levels.bass) * 0.3 : 0)
        .animation(.easeOut(duration: 0.12), value: levels.bass)
        .animation(.easeInOut(duration: 0.8), value: on)
        .allowsHitTesting(false)
    }
}

// MARK: - Pieces

/// Album art that "drips" in from the top when it changes.
struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    @State private var shown: NSImage?
    @State private var previous: NSImage?
    @State private var reveal: CGFloat = 1

    var body: some View {
        ZStack {
            art(previous)
            art(shown).mask(DripMask(progress: reveal))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onAppear { shown = image }
        .onChange(of: image) { _, new in
            previous = shown
            shown = new
            reveal = 0
            withAnimation(.easeIn(duration: 0.9)) { reveal = 1 }
        }
    }

    @ViewBuilder private func art(_ img: NSImage?) -> some View {
        if let img {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(white: 0.16)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// A curtain with paint-like drips on its leading edge, sliding down as progress goes 0 → 1.
struct DripMask: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // (x position, width, extra length) as fractions of the size.
    private let drips: [(CGFloat, CGFloat, CGFloat)] = [(0.1, 0.16, 0.35), (0.36, 0.13, 0.55), (0.6, 0.18, 0.25), (0.84, 0.14, 0.45)]

    func path(in r: CGRect) -> Path {
        let base = (progress * 1.6 - 0.6) * r.height
        var p = Path()
        p.addRect(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(base, 0)))
        for (x, w, len) in drips {
            let dw = w * r.width
            let rect = CGRect(x: r.minX + x * r.width - dw / 2, y: r.minY, width: dw, height: max(base + len * r.height, 0))
            p.addRoundedRect(in: rect, cornerSize: CGSize(width: dw / 2, height: dw / 2))
        }
        return p
    }
}

struct Bars: View {
    @ObservedObject var levels: AudioLevels
    let playing: Bool
    let color: Color
    let height: CGFloat

    var body: some View {
        if playing && levels.hasSignal {
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(color).frame(width: 3, height: max(3, height * (0.15 + 0.85 * levels.bands[i])))
                }
            }
            .frame(height: height)
            .animation(.linear(duration: 0.05), value: levels.bands)
        } else {
            // No audio access (or paused): a gentle fake wave.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        let d = Double(i)
                        let level = playing ? 0.3 + 0.7 * abs(sin(t * (2.6 + d * 1.15) + d * 1.7)) : 0.18
                        Capsule().fill(color).frame(width: 3, height: max(3, height * level))
                    }
                }
                .frame(height: height)
            }
        }
    }
}

struct ProgressBar: View {
    @ObservedObject var player: NowPlaying
    let tint: Color
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = max(player.track?.duration ?? 0, 0.001)
            let pos = scrub ?? player.position(at: ctx.date)
            HStack(spacing: 10) {
                Text(clock(pos)).frame(width: 34, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(tint).frame(width: geo.size.width * min(pos / duration, 1))
                    }
                    .frame(height: scrub == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in scrub = duration * min(max(v.location.x / geo.size.width, 0), 1) }
                        .onEnded { _ in
                            if let s = scrub { player.seek(to: s) }
                            scrub = nil
                        })
                }
                .frame(height: 12)
                Text(clock(duration)).frame(width: 34, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
                .scaleEffect(hover ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A tappable on/off pill for the settings panel.
struct SettingPill: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    @State private var hover = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.black : .white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isOn ? Color.white : .white.opacity(0.1)))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(isOn ? 1 : 0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

/// A one-shot action styled like a settings pill.
struct ActionPill: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.teal.opacity(0.6)))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 22)
                .background(Capsule().fill(.white.opacity(hover ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
