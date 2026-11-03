import AudioToolbox
import CoreHaptics
import Foundation

/// Guest vibrator -> CoreHaptics continuous event of the requested length.
final class HapticsBridge {
    private var engine: CHHapticEngine?
    private let queue = DispatchQueue(label: "va.haptics")
    private var count = 0
    private lazy var supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// Engine thread.
    func vibrate(milliseconds: UInt32) {
        queue.async { [self] in
            count += 1
            guard milliseconds > 0 else { return }
            guard supported else {
                #if !targetEnvironment(simulator)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                #endif
                return
            }
            do {
                let engine = try self.engine ?? makeEngine()
                let duration = min(Double(milliseconds) / 1000, 30)
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ], relativeTime: 0, duration: duration)
                let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
                try engine.start()
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                self.engine = nil
            }
        }
    }

    private func makeEngine() throws -> CHHapticEngine {
        let e = try CHHapticEngine()
        e.isAutoShutdownEnabled = true
        e.resetHandler = { [weak self] in self?.queue.async { self?.engine = nil } }
        engine = e
        return e
    }

    var status: String { "Haptics: \(supported ? "CoreHaptics" : "unsupported") vibrations=\(count)" }
}
