import Foundation
import IOSurface

/// Which engine implementation to use. `.auto` picks QEMU when the engine
/// frameworks are embedded and an image is installed, the stub otherwise.
enum EngineKind: String, CaseIterable, Identifiable, Codable {
    case auto, stub, qemu
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .stub: return "Stub (test pattern)"
        case .qemu: return "QEMU (real Android)"
        }
    }
}

/// A composed guest frame, as delivered by VaGfxPresentFn (or the stub).
struct DisplayFrame {
    let surface: IOSurfaceRef
    let width: Int
    let height: Int
    /// Extra clockwise rotation the presenter applies to this frame (VaGfxFrame.rotation_deg).
    let rotationDegrees: Int
    let number: UInt64
}

/// Receives frames from any thread. Implementations must be thread-safe.
protocol FrameSink: AnyObject {
    func present(_ frame: DisplayFrame)
}

/// Platform -> engine events (va_engine_* in va_host.h). Thread-safe.
protocol EngineInput: AnyObject {
    func touch(_ points: [VaTouchPoint])
    func key(_ linuxKeycode: UInt32, down: Bool)
    func sensorEvent(_ type: VaSensorType, values: [Float], timestampNs: Int64)
    func locationUpdate(_ location: VaLocation)
    func batteryChanged()
    func clipboardFromHost(_ text: String)
    /// Android Surface rotation semantics: degrees the device is rotated
    /// counter-clockwise from its natural (portrait) orientation.
    func setDisplayRotation(_ degrees: Int)
}

/// Engine -> app notifications. Always delivered on the main queue.
protocol EngineDelegate: AnyObject {
    func engine(_ engine: VMEngine, guestStateChanged state: VaGuestState)
    func engine(_ engine: VMEngine, bootProgress fraction: Double, message: String)
    func engine(_ engine: VMEngine, didExitWithStatus status: Int32, fatal: Bool, message: String?)
    func engine(_ engine: VMEngine, log level: Int32, message: String)
    /// Restore (config.restoreStateFile) finished loading; the guest is paused
    /// and runs only after `resume()`.
    func engine(_ engine: VMEngine, restoreFinished result: Result<Void, Error>)
}

/// Everything an engine needs to boot the VM.
struct VMLaunchConfig {
    var displayWidth = 1080
    var displayHeight = 2340
    var displayDPI = 440
    var refreshHz = 60
    var memoryMB = 2048
    var cpuCount = 4
    /// Paths/argv only used by the QEMU engine.
    var storage: VMStorage?
    /// M4: guest RAM in storage.ramImage (shared file) + ranchu snapshot-dir.
    var snapshotMode = false
    /// M4: restore from this state file (QEMU: -incoming defer + migrate-incoming).
    var restoreStateFile: URL?
    /// QEMU machine; "ranchu" (board) or "virt" for frameworks without it.
    var machine = "ranchu"
    /// adb on 127.0.0.1:port (ranchu: va-vsock-pci). Default: 5570 on the
    /// simulator (run-macos.sh uses 5555, run_sim.sh 5590), off on devices.
    var adbPort: Int?
    var traceEvents: [String] = []
    /// Dev: libva_gfx also writes frames as PNGs here (VA_DUMP_FRAMES).
    var dumpFramesDir: String?
}

enum EngineError: LocalizedError {
    case frameworkMissing(String)
    case imageMissing(String)
    case startFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .frameworkMissing(let s): return "Engine framework missing: \(s)"
        case .imageMissing(let s): return "Android image not installed: \(s)"
        case .startFailed(let s): return "Engine failed to start: \(s)"
        case .unsupported(let s): return s
        }
    }
}

protocol VMEngine: EngineInput {
    var displayName: String { get }
    var delegate: EngineDelegate? { get set }
    func start(config: VMLaunchConfig, host: HostBridge, frames: FrameSink) throws
    /// Stop the guest (QMP `stop`).
    func pause()
    /// Run the guest (QMP `cont`).
    func resume()
    /// M4 suspend: stop, then save device state to `stateFile` (cpr-reboot,
    /// x-ignore-shared). The engine stays alive, paused. Completion on main.
    func suspend(stateFile: URL, completion: @escaping (Result<Void, Error>) -> Void)
    /// ACPI-style power button request (guest shuts down cleanly).
    func requestShutdown()
    /// Hard stop (quit).
    func forceStop()
}

/// Monotonic host clock used for sensor timestamps (CLOCK_UPTIME_RAW, ns),
/// same time base as CoreMotion's CMLogItem.timestamp.
@inline(__always) func hostMonotonicNs() -> Int64 {
    Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
}

extension VaGuestState: CustomStringConvertible {
    public var description: String {
        switch self {
        case VA_GUEST_STOPPED: return "stopped"
        case VA_GUEST_BOOTING: return "booting"
        case VA_GUEST_BOOT_COMPLETED: return "boot completed"
        case VA_GUEST_PAUSED: return "paused"
        case VA_GUEST_SHUTDOWN: return "shutdown"
        default: return "state \(rawValue)"
        }
    }
}
