import AppKit
import AVFoundation
import Vision

/// Watches the FaceTime camera (which lives in the notch) with on-device Vision:
/// - presence: is someone in front of the Mac (walk-away pause)
/// - gaze: are they looking up at the notch (look to wake), using a per-user calibration
/// - hands: open palm and side swipes (air gestures)
/// Frames are analyzed in memory at ~12 fps and never stored.
final class CameraSensor: NSObject, ObservableObject {
    enum Status: Equatable { case off, denied, watching, noFace }
    enum Gesture { case playPause, next, previous }

    @Published private(set) var status: Status = .off
    @Published private(set) var looking = false
    @Published private(set) var calibrated = false
    @Published private(set) var calibrating = false

    var onGesture: ((Gesture) -> Void)?
    var onAway: (() -> Void)?
    var onReturn: ((TimeInterval) -> Void)?
    /// symbol, title, subtitle, seconds on screen
    var onPrompt: ((String, String, String, TimeInterval) -> Void)?

    // Main-thread config.
    private var config = (enabled: false, look: false, gestures: false, away: false)
    private var suspended = false
    private var running = false

    // Camera-queue state.
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "hum.camera", qos: .userInitiated)
    private var configured = false
    private var wantLook = false, wantHands = false, wantAway = false
    private var lastFrame: CFTimeInterval = 0
    private let faceRequest = VNDetectFaceLandmarksRequest()
    /// Revision 3 reports head pitch/yaw, which the landmarks request leaves empty.
    private let poseRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()
    private var pose: (pitch: Double, yaw: Double) = (0, 0)
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    // Presence
    private var lastFaceSeen: CFTimeInterval = 0
    private var faceStreakStart: CFTimeInterval?
    private var away = false
    private var awaySince = Date()
    private var lastStatus: Status = .off

    // Gaze
    private var calNotch: [Double]?
    private var calScreen: [Double]?
    private var calSigma: [Double]?
    private var collecting: String?
    private var samples: [String: [[Double]]] = [:]
    private var smoothT = 0.0
    private var lookOn: CFTimeInterval?
    private var lookOff: CFTimeInterval?
    private var lookState = false
    private var lastDebug: CFTimeInterval = 0
    private static let debug = ProcessInfo.processInfo.environment["HUM_DEBUG"] != nil

    // Hands
    private var trail: [(CFTimeInterval, CGFloat)] = []
    private var palmSince: CFTimeInterval?
    private var palmLatched = false
    private var handFirstSeen: CFTimeInterval?
    private var handLastSeen: CFTimeInterval = 0
    private var lastOpen: CFTimeInterval = 0
    private var lastHandDebug: CFTimeInterval = 0
    private var cooldownUntil: CFTimeInterval = 0

    override init() {
        super.init()
        let d = UserDefaults.standard
        // v2 calibration (with head pose and noise). Older calibrations had no usable signal.
        if let n = d.array(forKey: "gaze2Notch") as? [Double], let s = d.array(forKey: "gaze2Screen") as? [Double],
           let sig = d.array(forKey: "gaze2Sigma") as? [Double] {
            calNotch = n
            calScreen = s
            calSigma = sig
            calibrated = true
        }
    }

    // MARK: Control (main thread)

    func configure(enabled: Bool, look: Bool, gestures: Bool, away: Bool) {
        config = (enabled, look, gestures, away)
        apply()
    }

    /// Stop while the screen is asleep or locked, so nobody gets marked "away".
    func setSuspended(_ value: Bool) {
        suspended = value
        apply()
    }

    private func apply() {
        let c = config
        queue.async {
            self.wantLook = c.look
            self.wantHands = c.gestures
            self.wantAway = c.away
        }
        let needed = !suspended && c.enabled && (c.look || c.gestures || c.away || calibrating)
        needed ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.apply() : (self.status = .denied) }
            }
            return
        default:
            status = .denied
            return
        }
        running = true
        status = .noFace
        queue.async {
            if !self.configured && !self.setupSession() {
                DispatchQueue.main.async { self.running = false; self.status = .denied }
                return
            }
            self.resetTracking()
            self.session.startRunning()
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        status = .off
        looking = false
        queue.async {
            self.session.stopRunning()
            // Don't leave music or focus paused because the camera went off mid-"away".
            if self.away {
                let gone = Date().timeIntervalSince(self.awaySince) + 10
                DispatchQueue.main.async { self.onReturn?(gone) }
            }
            self.resetTracking()
        }
    }

    private func setupSession() -> Bool {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.localizedName.contains("FaceTime") }) ?? devices.first,
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        return true
    }

    // Camera queue.
    private func resetTracking() {
        lastFaceSeen = CACurrentMediaTime()
        faceStreakStart = nil
        away = false
        trail.removeAll()
        palmSince = nil
        palmLatched = false
        lookOn = nil
        lookOff = nil
        lookState = false
        lastStatus = .off
    }

    // MARK: Calibration

    /// Two short steps: look at the notch, then at the middle of the screen.
    func calibrate() {
        guard !calibrating else { return }
        if !config.enabled { config.enabled = true }
        calibrating = true
        apply()

        onPrompt?("arrow.up.circle.fill", "Look up at the notch", "Tilt your head a little toward it…", 2.9)
        after(1.2) { self.queue.async { self.samples = [:]; self.collecting = "notch" } }
        after(3.2) {
            self.queue.async { self.collecting = nil }
            self.onPrompt?("arrow.down.circle.fill", "Now look at the middle of your screen", "Keep your eyes there…", 2.9)
        }
        after(4.8) { self.queue.async { self.collecting = "screen" } }
        after(6.8) {
            self.queue.async {
                self.collecting = nil
                let n = self.samples["notch"] ?? [], s = self.samples["screen"] ?? []
                var result = "face"
                if n.count >= 6 && s.count >= 6 {
                    let mn = Self.mean(n), ms = Self.mean(s)
                    // Per-signal jitter, floored so one perfectly still signal can't dominate.
                    let floors = [0.01, 0.01, 0.02, 0.005]
                    let sigma = (0..<mn.count).map { i -> Double in
                        let all = n.map { $0[i] - mn[i] } + s.map { $0[i] - ms[i] }
                        return max(sqrt(all.map { $0 * $0 }.reduce(0, +) / Double(all.count)), floors[i])
                    }
                    // How many "jitters" apart notch and screen are.
                    let separation = sqrt(zip(zip(mn, ms), sigma).map { pow(($0.0 - $0.1) / $1, 2) }.reduce(0, +))
                    NSLog("Hum gaze calibration: notch \(mn) screen \(ms) sigma \(sigma) separation \(separation)")
                    if separation >= 3 {
                        self.calNotch = mn
                        self.calScreen = ms
                        self.calSigma = sigma
                        let d = UserDefaults.standard
                        d.set(mn, forKey: "gaze2Notch")
                        d.set(ms, forKey: "gaze2Screen")
                        d.set(sigma, forKey: "gaze2Sigma")
                        result = "ok"
                    } else {
                        result = "weak"
                    }
                }
                DispatchQueue.main.async {
                    self.calibrating = false
                    if result == "ok" { self.calibrated = true }
                    self.apply()
                    switch result {
                    case "ok":
                        self.onPrompt?("checkmark.circle.fill", "Gaze calibrated", "Glance up at the notch to open it", 3.5)
                    case "weak":
                        self.onPrompt?("exclamationmark.triangle.fill", "Couldn't tell notch from screen",
                                       "Try again and tilt your head up a bit more", 4)
                    default:
                        self.onPrompt?("exclamationmark.triangle.fill", "Couldn't see your face",
                                       "Sit in front of the camera and try again", 3.5)
                    }
                }
            }
        }
    }

    private func after(_ s: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work)
    }

    private static func mean(_ rows: [[Double]]) -> [Double] {
        (0..<rows[0].count).map { i in rows.map { $0[i] }.reduce(0, +) / Double(rows.count) }
    }

    // MARK: Face: presence and gaze (camera queue)

    private func processFace(_ face: VNFaceObservation?, _ now: CFTimeInterval) {
        if face != nil {
            lastFaceSeen = now
            if faceStreakStart == nil { faceStreakStart = now }
        } else {
            faceStreakStart = nil
        }
        publishStatus(face != nil ? .watching : .noFace)

        if wantAway {
            if !away && now - lastFaceSeen > 10 {
                away = true
                awaySince = Date()
                DispatchQueue.main.async { self.onAway?() }
            } else if away, let s = faceStreakStart, now - s > 1 {
                away = false
                let gone = Date().timeIntervalSince(awaySince) + 10
                DispatchQueue.main.async { self.onReturn?(gone) }
            }
        }

        let f = face.map(features)
        if Self.debug, let f, now - lastDebug > 1 {
            lastDebug = now
            NSLog("Hum gaze: pitch %.3f yaw %.3f pupil %.3f faceY %.3f t %.2f", f[0], f[1], f[2], f[3], smoothT)
        }
        if let c = collecting, let f { samples[c, default: []].append(f) }
        guard wantLook else { return }

        var raw = false
        if let f, let notch = calNotch, let screen = calScreen, let sigma = calSigma {
            // Project onto the screen → notch direction, weighting each signal by how steady it is:
            // 0 = looking at the screen, 1 = looking at the notch.
            let w = zip(zip(notch, screen), sigma).map { ($0.0 - $0.1) / ($1 * $1) }
            let norm = zip(zip(notch, screen), w).map { ($0.0 - $0.1) * $1 }.reduce(0, +)
            if norm > 1e-9 {
                let t = zip(zip(f, screen), w).map { ($0.0 - $0.1) * $1 }.reduce(0, +) / norm
                smoothT = smoothT * 0.7 + t * 0.3
                // Hysteresis: clearly notch to open, clearly screen to close.
                raw = lookState ? smoothT > 0.4 : smoothT > 0.75
            }
        }
        if raw { lookOn = lookOn ?? now; lookOff = nil } else { lookOff = lookOff ?? now; lookOn = nil }
        if !lookState, let s = lookOn, now - s > 0.4 { setLooking(true) }
        if lookState, let s = lookOff, now - s > 0.8 { setLooking(false) }
    }

    private func setLooking(_ v: Bool) {
        lookState = v
        DispatchQueue.main.async { self.looking = v }
    }

    private func publishStatus(_ s: Status) {
        guard s != lastStatus else { return }
        lastStatus = s
        DispatchQueue.main.async { if self.running { self.status = s } }
    }

    /// Head pitch & yaw, where the pupils sit inside the eyes, and face height in frame.
    private func features(_ o: VNFaceObservation) -> [Double] {
        func rel(_ eye: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> Double? {
            guard let e = eye?.normalizedPoints, e.count > 2, let p = pupil?.normalizedPoints.first else { return nil }
            let ys = e.map(\.y)
            guard let lo = ys.min(), let hi = ys.max(), hi - lo > 0.001 else { return nil }
            return Double((p.y - lo) / (hi - lo))
        }
        let pupils = [rel(o.landmarks?.leftEye, o.landmarks?.leftPupil),
                      rel(o.landmarks?.rightEye, o.landmarks?.rightPupil)].compactMap { $0 }
        let pupil = pupils.isEmpty ? 0.5 : pupils.reduce(0, +) / Double(pupils.count)
        return [pose.pitch, pose.yaw, pupil, Double(o.boundingBox.midY)]
    }

    // MARK: Hands: gestures (camera queue)

    private func processHand(_ hand: VNHumanHandPoseObservation?, _ now: CFTimeInterval) {
        let pts = hand.flatMap { try? $0.recognizedPoints(.all) }
        func p(_ j: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let x = pts?[j], x.confidence > 0.3 else { return nil }
            return x.location
        }
        // Vision drops the odd frame; only forget the hand after it's been gone a moment.
        guard let wrist = p(.wrist), let mcp = p(.middleMCP) else {
            if now - handLastSeen > 0.35 { resetHand() }
            return
        }
        handLastSeen = now
        if handFirstSeen == nil { handFirstSeen = now }

        let fingers: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] =
            [(.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP)]
        let extended = fingers.filter { tip, pip in
            guard let t = p(tip), let q = p(pip) else { return false }
            return hypot(t.x - wrist.x, t.y - wrist.y) > hypot(q.x - wrist.x, q.y - wrist.y) * 1.1
        }.count
        let open = extended >= 3
        if open {
            lastOpen = now
            if palmSince == nil { palmSince = now }
        } else if now - lastOpen > 0.3 {
            palmSince = nil
            palmLatched = false // close your hand (or lower it) to re-arm
        }

        // Ignore the motion of the hand coming into frame.
        guard let first = handFirstSeen, now - first > 0.3 else { return }
        let x = 1 - (wrist.x + mcp.x) / 2 // mirrored, so "right" is the user's right
        trail.append((now, x))
        trail.removeAll { now - $0.0 > 0.6 }
        let xs = trail.map(\.1)
        let drift = (xs.max() ?? 0) - (xs.min() ?? 0)

        if Self.debug && now - lastHandDebug > 0.5 {
            lastHandDebug = now
            NSLog("Hum hand: fingers %d open %d drift %.3f palm %.2fs latched %d",
                  extended, open ? 1 : 0, drift, palmSince.map { now - $0 } ?? 0, palmLatched ? 1 : 0)
        }
        guard now > cooldownUntil, let start = trail.first else { return }

        // Swipe: a quick sideways move.
        let dx = x - start.1
        if now - start.0 > 0.12 && abs(dx) > 0.22 {
            fire(dx > 0 ? .next : .previous)
            cooldownUntil = now + 1.2
            trail.removeAll()
            palmSince = nil
            palmLatched = true
            return
        }

        // Open palm held fairly still → play/pause.
        if open, !palmLatched, drift < 0.1, let s = palmSince, now - s > 0.5 {
            fire(.playPause)
            palmLatched = true
            cooldownUntil = now + 1.2
        }
    }

    private func resetHand() {
        trail.removeAll()
        palmSince = nil
        palmLatched = false
        handFirstSeen = nil
    }

    private func fire(_ g: Gesture) {
        if Self.debug { NSLog("Hum gesture: \(g)") }
        DispatchQueue.main.async { self.onGesture?(g) }
    }
}

extension CameraSensor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame > 1.0 / 12, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now

        let needFace = wantLook || wantAway || collecting != nil
        var requests: [VNRequest] = []
        if needFace { requests += [faceRequest, poseRequest] }
        if wantHands { requests.append(handRequest) }
        guard !requests.isEmpty else { return }

        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform(requests)
        if needFace {
            if let p = poseRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                pose = (p.pitch?.doubleValue ?? 0, p.yaw?.doubleValue ?? 0)
            }
            let face = faceRequest.results?.max { $0.boundingBox.width < $1.boundingBox.width }
            processFace(face, now)
        }
        if wantHands { processHand(handRequest.results?.first, now) }
    }
}
