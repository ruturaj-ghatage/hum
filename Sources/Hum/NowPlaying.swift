import AppKit
import Combine

enum PlayerApp: String {
    case spotify = "Spotify"
    case music = "Music"

    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double // seconds
}

/// Watches Spotify (and Apple Music) through their distributed notifications and
/// talks back to them with AppleScript for artwork, position and controls.
final class NowPlaying: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: NSColor = .white
    @Published private(set) var source: PlayerApp = .spotify

    /// Fires when a new song starts, so the notch can peek.
    let trackChanged = PassthroughSubject<Void, Never>()

    private var position: Double = 0
    private var positionStamp = Date()
    private let scriptQueue = DispatchQueue(label: "hum.applescript")

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)),
                        name: .init("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)),
                        name: .init("com.apple.Music.playerInfo"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                        name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        if isRunning(.spotify) { refresh(.spotify, announce: false) }
        else if isRunning(.music) { refresh(.music, announce: false) }
    }

    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionStamp) : position
        return min(max(p, 0), max(track.duration, 0))
    }

    // MARK: Controls

    func playPause() {
        position = position(at: Date()); positionStamp = Date()
        isPlaying.toggle()
        send("playpause")
    }
    func next() { send("next track") }
    func previous() { send("previous track") }
    func seek(to seconds: Double) {
        position = seconds; positionStamp = Date()
        send("set player position to \(seconds)")
    }

    /// Re-reads position/state from the player (e.g. after a seek inside Spotify).
    func resync() {
        if isRunning(source) { refresh(source, announce: true) }
    }

    func openPlayer() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func send(_ command: String) {
        guard isRunning(source) else { return }
        let app = source.rawValue
        scriptQueue.async { Self.run("tell application \"\(app)\" to \(command)") }
    }

    // MARK: Notifications

    @objc private func spotifyChanged(_ n: Notification) {
        let info = n.userInfo ?? [:]
        let state = info["Player State"] as? String ?? "Stopped"
        guard state != "Stopped" else { clear(); return }
        source = .spotify
        let t = Track(id: info["Track ID"] as? String ?? "",
                      title: info["Name"] as? String ?? "",
                      artist: info["Artist"] as? String ?? "",
                      album: info["Album"] as? String ?? "",
                      duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        apply(t, playing: state == "Playing",
              position: (info["Playback Position"] as? NSNumber)?.doubleValue, announce: true)
    }

    @objc private func musicChanged(_ n: Notification) {
        let info = n.userInfo ?? [:]
        let state = info["Player State"] as? String ?? "Stopped"
        guard state != "Stopped" else { if source == .music { clear() }; return }
        source = .music
        let title = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let pid = (info["PersistentID"] as? NSNumber)?.stringValue ?? "\(title)|\(artist)"
        let t = Track(id: pid, title: title, artist: artist,
                      album: info["Album"] as? String ?? "",
                      duration: ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        apply(t, playing: state == "Playing", position: nil, announce: true)
        // Music's notification doesn't include the position.
        refresh(.music, announce: true)
    }

    @objc private func appTerminated(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == source.bundleID { clear() }
    }

    // MARK: State

    private func apply(_ t: Track, playing: Bool, position p: Double?, announce: Bool) {
        let isNew = t.id != track?.id
        track = t
        isPlaying = playing
        if let p { position = p; positionStamp = Date() }
        else if isNew { position = 0; positionStamp = Date() }
        if isNew {
            artwork = nil
            fetchArtwork(for: t, from: source)
            if announce { trackChanged.send() }
        }
    }

    private func clear() {
        track = nil
        isPlaying = false
        artwork = nil
    }

    private func isRunning(_ app: PlayerApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    /// Full state query via AppleScript. Only called when the app is running,
    /// since `tell application` would otherwise launch it.
    private func refresh(_ app: PlayerApp, announce: Bool) {
        let durationExpr = app == .spotify ? "(duration of t) / 1000" : "duration of t"
        let idExpr = app == .spotify ? "id of t" : "persistent ID of t"
        let script = """
        tell application "\(app.rawValue)"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {player state as string, \(idExpr), name of t, artist of t, album of t, \(durationExpr), player position}
        end tell
        """
        scriptQueue.async {
            guard let d = Self.run(script) else { return }
            let state = d.atIndex(1)?.stringValue?.lowercased() ?? "stopped"
            DispatchQueue.main.async {
                guard state != "stopped", d.numberOfItems >= 7 else {
                    if self.source == app { self.clear() }
                    return
                }
                self.source = app
                var t = Track(id: d.atIndex(2)?.stringValue ?? "",
                              title: d.atIndex(3)?.stringValue ?? "",
                              artist: d.atIndex(4)?.stringValue ?? "",
                              album: d.atIndex(5)?.stringValue ?? "",
                              duration: d.atIndex(6)?.doubleValue ?? 0)
                // Keep the notification's id for Music so they match.
                if app == .music, let current = self.track, current.title == t.title, current.artist == t.artist {
                    t.id = current.id
                }
                self.apply(t, playing: state == "playing", position: d.atIndex(7)?.doubleValue, announce: announce)
            }
        }
    }

    private func fetchArtwork(for t: Track, from app: PlayerApp) {
        scriptQueue.async {
            var image: NSImage?
            switch app {
            case .spotify:
                if let s = Self.run("tell application \"Spotify\" to return artwork url of current track")?.stringValue,
                   let url = URL(string: s), let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            case .music:
                if let data = Self.run("tell application \"Music\" to return raw data of artwork 1 of current track")?.data {
                    image = NSImage(data: data)
                }
            }
            let tint = image.map(Self.tint(of:)) ?? .white
            DispatchQueue.main.async {
                guard self.track?.id == t.id else { return }
                self.artwork = image
                self.tint = tint
            }
        }
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Hum AppleScript error: \(error)") }
        return error == nil ? result : nil
    }

    /// Picks the most vivid color in the artwork, lifted so it reads on black.
    private static func tint(of image: NSImage) -> NSColor {
        let side = 10
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let ptr = { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side)); return ctx.data }()
        else { return .white }

        let px = ptr.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var best: (score: CGFloat, color: NSColor) = (-1, .white)
        for i in 0..<(side * side) {
            let c = NSColor(red: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255,
                            blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            let score = c.saturationComponent * (0.4 + c.brightnessComponent)
            if score > best.score { best = (score, c) }
        }
        let c = best.color
        if c.saturationComponent < 0.15 { return .white }
        return NSColor(hue: c.hueComponent, saturation: min(c.saturationComponent, 0.85),
                       brightness: max(c.brightnessComponent, 0.85), alpha: 1)
    }
}
