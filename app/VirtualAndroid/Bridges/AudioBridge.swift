import AVFoundation
import Foundation

/// Guest audio <-> AVAudioEngine.
///  * Speaker: the engine pushes PCM16 interleaved frames (speaker_write) into a
///    lock-free ring; an AVAudioSourceNode pulls them on the render thread.
///  * Microphone: an input tap converts to PCM16 interleaved at the guest's
///    rate/channels into a ring the engine drains with mic_read.
/// The record permission prompt appears only when the guest opens the mic.
final class AudioBridge {
    private let queue = DispatchQueue(label: "va.audio")
    private let lock = NSLock()

    // Speaker state.
    private var speakerEngine: AVAudioEngine?
    private var speakerRing: OpaquePointer?
    private var speakerChannels = 2
    private var speakerRate = 48000
    private var speakerWanted = false
    private var underruns: UInt64 = 0
    private static let scratchFrames = 4096
    private let speakerScratch = UnsafeMutablePointer<Int16>.allocate(capacity: AudioBridge.scratchFrames * 2)
    private var framesPlayed: UInt64 = 0

    // Microphone state.
    private var micEngine: AVAudioEngine?
    private var micRing: OpaquePointer?
    private var micChannels = 1
    private var micRate = 16000
    private var micWanted = false
    private var micDenied = false

    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                        queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.queue.async { self.restartAll() }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                        queue: nil) { [weak self] _ in
            self?.queue.async { self?.restartAll() }
        })
    }

    // MARK: Speaker (engine threads)

    func speakerStart(sampleRate: Int, channels: Int) -> Bool {
        guard sampleRate > 0, (1...2).contains(channels) else { return false }
        lock.lock()
        let old = speakerRing
        speakerRate = sampleRate
        speakerChannels = channels
        speakerRing = va_ring_create(sampleRate * channels / 4)    // ~250 ms
        speakerWanted = true
        lock.unlock()
        queue.async {
            // Stop the render callback that may still read the old ring first.
            self.speakerEngine?.stop()
            self.speakerEngine = nil
            if let old { va_ring_destroy(old) }
            self.startSpeakerEngine()
        }
        return true
    }

    func speakerStop() {
        lock.lock()
        speakerWanted = false
        lock.unlock()
        queue.async {
            self.speakerEngine?.stop()
            self.speakerEngine = nil
            self.lock.lock()
            if let r = self.speakerRing { self.speakerRing = nil; va_ring_destroy(r) }
            self.lock.unlock()
            self.updateSession()
        }
    }

    /// Returns frames accepted; fewer than `frames` means the ring is full
    /// (natural back-pressure, like a real DAC).
    func speakerWrite(_ src: UnsafePointer<Int16>, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = speakerRing else { return 0 }
        let ch = speakerChannels
        let written = va_ring_write(ring, src, frames * ch)
        return written / ch
    }

    private func startSpeakerEngine() {
        lock.lock()
        let wanted = speakerWanted
        let rate = Double(speakerRate)
        let ch = speakerChannels
        let ring = speakerRing
        lock.unlock()
        guard wanted, let ring else { return }
        speakerEngine?.stop()
        updateSession()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(ch)) else {
            return
        }
        let scratchFrames = Self.scratchFrames
        let scratch = speakerScratch
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            var done = 0
            let total = Int(frameCount)
            var short = false
            while done < total {
                let chunk = min(scratchFrames, total - done)
                let got = va_ring_read(ring, scratch, chunk * ch) / ch
                if got < chunk { short = true }
                for c in 0..<min(ch, buffers.count) {
                    guard let out = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<chunk {
                        out[done + f] = f < got ? Float(scratch[f * ch + c]) / 32768 : 0
                    }
                }
                done += chunk
            }
            if short { self?.underruns &+= 1 }
            self?.framesPlayed &+= UInt64(total)
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            speakerEngine = engine
        } catch {
            NSLog("VirtualAndroid: speaker engine failed: \(error)")
        }
    }

    // MARK: Microphone (engine threads)

    func micStart(sampleRate: Int, channels: Int) -> Bool {
        guard sampleRate > 0, (1...2).contains(channels) else { return false }
        lock.lock()
        let old = micRing
        micRate = sampleRate
        micChannels = channels
        micRing = va_ring_create(sampleRate * channels / 2)     // ~500 ms
        micWanted = true
        lock.unlock()
        // Delivers silence (mic_read returns 0) until permission is granted.
        queue.async {
            if let e = self.micEngine {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
                self.micEngine = nil
            }
            if let old { va_ring_destroy(old) }
            self.requestMicPermissionThenStart()
        }
        return true
    }

    func micStop() {
        lock.lock()
        micWanted = false
        lock.unlock()
        queue.async {
            if let e = self.micEngine {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
            }
            self.micEngine = nil
            self.lock.lock()
            if let r = self.micRing { self.micRing = nil; va_ring_destroy(r) }
            self.lock.unlock()
            self.updateSession()
        }
    }

    func micRead(into dst: UnsafeMutablePointer<Int16>, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let ring = micRing else { return 0 }
        return va_ring_read(ring, dst, frames * micChannels) / micChannels
    }

    private func requestMicPermissionThenStart() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startMicEngine()
        case .denied:
            micDenied = true
        default:
            AVAudioApplication.requestRecordPermission { granted in
                self.queue.async {
                    self.micDenied = !granted
                    if granted { self.startMicEngine() }
                }
            }
        }
    }

    private func startMicEngine() {
        lock.lock()
        let wanted = micWanted
        let ring = micRing
        let rate = Double(micRate)
        let ch = micChannels
        lock.unlock()
        guard wanted, let ring else { return }
        updateSession()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                            channels: AVAudioChannelCount(ch), interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            NSLog("VirtualAndroid: no usable microphone input")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * rate / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, let data = out.int16ChannelData?[0], out.frameLength > 0 {
                _ = va_ring_write(ring, data, Int(out.frameLength) * ch)
            }
        }
        do {
            try engine.start()
            micEngine = engine
        } catch {
            NSLog("VirtualAndroid: mic engine failed: \(error)")
        }
    }

    // MARK: Session

    private func updateSession() {
        let session = AVAudioSession.sharedInstance()
        lock.lock()
        let mic = micWanted && !micDenied
        let any = mic || speakerWanted
        lock.unlock()
        do {
            if mic {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            if any { try session.setActive(true) }
        } catch {
            NSLog("VirtualAndroid: audio session error: \(error)")
        }
    }

    private func restartAll() {
        lock.lock()
        let sp = speakerWanted
        let mic = micWanted
        lock.unlock()
        if sp, speakerEngine?.isRunning != true { startSpeakerEngine() }
        if mic, micEngine?.isRunning != true { startMicEngine() }
    }

    var status: String {
        lock.lock()
        defer { lock.unlock() }
        var parts: [String] = []
        parts.append(speakerWanted ? "speaker \(speakerRate)Hz/\(speakerChannels)ch underruns=\(underruns)" : "speaker off")
        parts.append(micWanted ? (micDenied ? "mic denied" : "mic \(micRate)Hz/\(micChannels)ch") : "mic off")
        return "Audio: " + parts.joined(separator: ", ")
    }
}
