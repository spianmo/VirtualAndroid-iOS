import Foundation

/// Implements `VaHostCallbacks` (va_host.h) on top of the iOS platform bridges.
///
/// The engine calls these C callbacks from its own threads; every bridge hops
/// to its own queue and never blocks the caller for long. Events flowing the
/// other way (sensor samples, location, battery, clipboard) are pushed through
/// `engine` (an `EngineInput`, i.e. the va_engine_* functions).
final class HostBridge {
    /// Events go to `engine` only while the guest runs: a suspended snapshot
    /// (ram.img + state.bin) must not change after it was taken.
    var engine: EngineInput? { forwarding ? target : nil }
    weak var target: EngineInput?
    var forwarding = true

    let motion = MotionBridge()
    let location = LocationBridge()
    let battery = BatteryBridge()
    let clipboard = ClipboardBridge()
    let camera = CameraBridge()
    let audio = AudioBridge()
    let haptics = HapticsBridge()

    /// Called on engine threads.
    var onLog: ((Int32, String) -> Void)?
    var onGuestState: ((VaGuestState) -> Void)?

    init() {
        motion.sink = { [weak self] type, values, ts in
            self?.engine?.sensorEvent(type, values: values, timestampNs: ts)
        }
        location.sink = { [weak self] loc in
            self?.engine?.locationUpdate(loc)
        }
        battery.onChange = { [weak self] in
            self?.engine?.batteryChanged()
        }
        clipboard.sink = { [weak self] text in
            self?.engine?.clipboardFromHost(text)
        }
    }

    /// Stop everything the guest turned on (engine stopped or app shut down).
    func stopAll() {
        motion.stopAll()
        location.setEnabled(false)
        camera.stopAll()
        audio.speakerStop()
        audio.micStop()
    }

    static func from(_ opaque: UnsafeMutableRawPointer?) -> HostBridge {
        Unmanaged<HostBridge>.fromOpaque(opaque!).takeUnretainedValue()
    }

    /// The struct handed to va_host_set_callbacks(). `opaque` is unretained:
    /// the owner (VMController) keeps the bridge alive longer than the engine.
    func makeCallbacks() -> VaHostCallbacks {
        var cb = VaHostCallbacks()
        cb.abi_version = UInt32(VA_HOST_ABI_VERSION)
        cb.opaque = Unmanaged.passUnretained(self).toOpaque()

        cb.log = { opaque, level, msg in
            guard let msg else { return }
            HostBridge.from(opaque).onLog?(level, String(cString: msg))
        }
        cb.guest_state_changed = { opaque, state in
            HostBridge.from(opaque).onGuestState?(state)
        }

        cb.sensor_set_enabled = { opaque, type, enabled, delayMs in
            HostBridge.from(opaque).motion.setEnabled(type, enabled: enabled, delayMs: delayMs)
        }
        cb.sensor_available_mask = { opaque in
            HostBridge.from(opaque).motion.availableMask
        }

        cb.location_set_enabled = { opaque, enabled in
            HostBridge.from(opaque).location.setEnabled(enabled)
        }

        cb.battery_get = { opaque, out in
            guard let out, let state = HostBridge.from(opaque).battery.current() else { return false }
            out.pointee = state
            return true
        }

        cb.clipboard_from_guest = { opaque, utf8, len in
            guard let utf8 else { return }
            let text = String(decoding: UnsafeRawBufferPointer(start: utf8, count: len), as: UTF8.self)
            HostBridge.from(opaque).clipboard.fromGuest(text)
        }

        cb.camera_count = { opaque in
            Int32(HostBridge.from(opaque).camera.count)
        }
        cb.camera_info = { opaque, index, out in
            guard let out, let info = HostBridge.from(opaque).camera.info(at: Int(index)) else { return false }
            out.pointee = info
            return true
        }
        cb.camera_start = { opaque, index, width, height in
            HostBridge.from(opaque).camera.start(index: Int(index), width: Int(width), height: Int(height))
        }
        cb.camera_stop = { opaque, index in
            HostBridge.from(opaque).camera.stop(index: Int(index))
        }
        cb.camera_read_frame = { opaque, index, dst, dstLen, ts in
            guard let dst else { return false }
            return HostBridge.from(opaque).camera.readFrame(index: Int(index), into: dst, capacity: dstLen,
                                                           timestampNs: ts)
        }

        cb.vibrate = { opaque, durationMs in
            HostBridge.from(opaque).haptics.vibrate(milliseconds: durationMs)
        }

        cb.mic_start = { opaque, rate, channels in
            HostBridge.from(opaque).audio.micStart(sampleRate: Int(rate), channels: Int(channels))
        }
        cb.mic_stop = { opaque in
            HostBridge.from(opaque).audio.micStop()
        }
        cb.mic_read = { opaque, dst, frames in
            guard let dst else { return 0 }
            return HostBridge.from(opaque).audio.micRead(into: dst, frames: frames)
        }

        cb.speaker_start = { opaque, rate, channels in
            HostBridge.from(opaque).audio.speakerStart(sampleRate: Int(rate), channels: Int(channels))
        }
        cb.speaker_stop = { opaque in
            HostBridge.from(opaque).audio.speakerStop()
        }
        cb.speaker_write = { opaque, src, frames in
            guard let src else { return 0 }
            return HostBridge.from(opaque).audio.speakerWrite(src, frames: frames)
        }
        return cb
    }

    /// One line per bridge, for the diagnostics sheet.
    func statusLines() -> [String] {
        [motion.status, location.status, battery.status, clipboard.status, camera.status,
         audio.status, haptics.status]
    }
}
