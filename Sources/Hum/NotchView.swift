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
    @ObservedObject var player: NowPlaying
    @ObservedObject var model: NotchModel

    var body: some View {
        let mode = model.mode(for: player)
        let size = model.size(for: mode)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if mode == .compact { compact.transition(.opacity) }
                if mode == .expanded { expanded.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top))) }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
            .padding(.horizontal, model.earRadius)
            .background(Color.black)
            .clipShape(NotchShape(bottomRadius: mode == .expanded ? 24 : 10, ear: model.earRadius))
            .shadow(color: .black.opacity(mode == .expanded ? 0.45 : 0), radius: 14, y: 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mode)
        .animation(.easeInOut(duration: 0.4), value: player.tint)
        .preferredColorScheme(.dark)
    }

    private var tint: Color { Color(nsColor: player.tint) }

    // MARK: Compact: art on the left wing, bars on the right wing

    private var compact: some View {
        let h = model.notchSize.height
        return HStack(spacing: 0) {
            Artwork(image: player.artwork, size: h - 10, radius: 5)
            Spacer(minLength: model.notchSize.width)
            Bars(playing: player.isPlaying, color: tint, height: 12)
                .frame(width: h - 10)
        }
        .padding(.horizontal, 8)
        .frame(height: h)
    }

    // MARK: Expanded: full player

    private var expanded: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: model.notchSize.height - 4)

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
                Bars(playing: player.isPlaying, color: tint, height: 16)
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
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Bars: View {
    let playing: Bool
    let color: Color
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
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

struct ProgressBar: View {
    @ObservedObject var player: NowPlaying
    let tint: Color
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = max(player.track?.duration ?? 0, 0.001)
            let pos = scrub ?? player.position(at: ctx.date)
            HStack(spacing: 10) {
                Text(format(pos)).frame(width: 34, alignment: .trailing)
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
                Text(format(duration)).frame(width: 34, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func format(_ s: Double) -> String {
        let s = Int(s.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
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
