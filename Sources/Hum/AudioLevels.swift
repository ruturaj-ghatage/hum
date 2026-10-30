import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Live frequency bands of whatever the Mac is playing, via a Core Audio process tap.
/// Needs the "System Audio Recording Only" permission; without it the tap delivers
/// silence and `hasSignal` stays false, so the UI falls back to fake bars.
final class AudioLevels: ObservableObject {
    @Published private(set) var bands: [CGFloat] = [0, 0, 0, 0]
    @Published private(set) var bass: CGFloat = 0
    @Published private(set) var hasSignal = false

    private var tap: AnyObject?
    private let size = 1024
    private var buffer: [Float] = []
    private var window: [Float] = []
    private var dft: vDSP.DiscreteFourierTransform<Float>?
    private var peaks: [Float] = [0.01, 0.01, 0.01, 0.01]
    private var smooth: [Float] = [0, 0, 0, 0]
    private var lastSignal = Date.distantPast
    private let edges: [Float] = [40, 160, 600, 2500, 9000] // Hz, 4 bands

    func start() {
        guard tap == nil else { return }
        guard #available(macOS 14.2, *) else { return }
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: size, direction: .forward,
                                                 transformType: .complexComplex, ofType: Float.self)
        let t = SystemAudioTap()
        t.onSamples = { [weak self] samples, frames, channels, rate in
            self?.ingest(samples, frames: frames, channels: channels, rate: rate)
        }
        do {
            try t.start()
            tap = t
        } catch {
            NSLog("Hum: audio tap failed: \(error)")
            t.stop()
        }
    }

    func stop() {
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
        buffer.removeAll()
        DispatchQueue.main.async {
            self.bands = [0, 0, 0, 0]
            self.bass = 0
            self.hasSignal = false
        }
    }

    // Runs on the tap's queue.
    private func ingest(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, rate: Double) {
        let ch = max(channels, 1)
        for f in 0..<frames {
            var s: Float = 0
            for c in 0..<ch { s += samples[f * ch + c] }
            buffer.append(s / Float(ch))
        }
        while buffer.count >= size {
            analyze(Array(buffer.prefix(size)), rate: Float(rate))
            buffer.removeFirst(size)
        }
    }

    private func analyze(_ frame: [Float], rate: Float) {
        guard let dft else { return }
        let input = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: size)
        var imag = [Float](repeating: 0, count: size)
        dft.transform(inputReal: input, inputImaginary: [Float](repeating: 0, count: size),
                      outputReal: &real, outputImaginary: &imag)
        let binHz = rate / Float(size)

        var levels = [Float](repeating: 0, count: 4)
        var loudest: Float = 0
        for b in 0..<4 {
            let lo = max(Int(edges[b] / binHz), 1), hi = min(Int(edges[b + 1] / binHz), size / 2 - 1)
            var sum: Float = 0
            for k in lo...max(lo, hi) {
                sum += sqrtf(real[k] * real[k] + imag[k] * imag[k])
            }
            let energy = sum / Float(max(hi - lo + 1, 1))
            loudest = max(loudest, energy)
            // Auto-gain per band: slowly decaying peak keeps quiet songs lively too.
            peaks[b] = max(peaks[b] * 0.996, energy, 0.01)
            let level = min(energy / peaks[b], 1)
            smooth[b] = level > smooth[b] ? level : smooth[b] * 0.82 + level * 0.18
            levels[b] = smooth[b]
        }
        if loudest > 0.002 { lastSignal = Date() }
        let live = Date().timeIntervalSince(lastSignal) < 2
        let result = levels.map { CGFloat($0) }
        DispatchQueue.main.async {
            self.bands = result
            self.bass = result[0]
            if self.hasSignal != live {
                self.hasSignal = live
                NSLog("Hum: audio signal \(live ? "live" : "silent")")
            }
        }
    }
}

/// Taps the mixed system output (excluding nothing) through a private aggregate device.
@available(macOS 14.2, *)
private final class SystemAudioTap {
    var onSamples: ((UnsafePointer<Float>, Int, Int, Double) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "hum.audiotap", qos: .userInteractive)

    struct TapError: Error { let step: String; let status: OSStatus }

    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        desc.name = "Hum"
        try check("create tap", AudioHardwareCreateProcessTap(desc, &tapID))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hum Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check("create aggregate", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check("tap format", AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format))
        let rate = format.mSampleRate

        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buf = list.first, let data = buf.mData else { return }
            let channels = Int(max(buf.mNumberChannels, 1))
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            self?.onSamples?(data.assumingMemoryBound(to: Float.self), frames, channels, rate)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw TapError(step: step, status: status) }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr else { throw TapError(step: "default output", status: status) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw TapError(step: "output uid", status: status) }
        return uid.takeRetainedValue() as String
    }
}
