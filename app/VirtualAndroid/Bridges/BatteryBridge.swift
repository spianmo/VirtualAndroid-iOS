import Foundation
import UIKit

/// UIDevice battery -> goldfish battery (battery_get + va_engine_battery_changed).
/// iOS exposes level and charging state only; voltage is a nominal value and
/// temperature is approximated from ProcessInfo.thermalState.
final class BatteryBridge {
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var cached: VaBatteryState?
    private var started = false
    private var observers: [NSObjectProtocol] = []

    /// Enables monitoring (main thread). Safe to call repeatedly.
    func start() {
        DispatchQueue.main.async { [self] in
            guard !started else { return }
            started = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
            let nc = NotificationCenter.default
            for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                         ProcessInfo.thermalStateDidChangeNotification] {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                    self?.onChange?()
                })
            }
        }
    }

    /// Thread-safe; nil when iOS does not know (simulator) -> engine reports AC/100%.
    func current() -> VaBatteryState? {
        if !started { start() }
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    var status: String {
        guard let s = current() else { return "Battery: unknown (engine default AC 100%)" }
        return "Battery: \(s.capacity_percent)% \(s.charging ? "charging" : s.ac_online ? "full/AC" : "discharging")"
    }

    private func refresh() {
        let device = UIDevice.current
        let level = device.batteryLevel
        var state: VaBatteryState?
        if level >= 0, device.batteryState != .unknown {
            var s = VaBatteryState()
            s.present = true
            s.capacity_percent = Int32((level * 100).rounded())
            switch device.batteryState {
            case .charging:
                s.ac_online = true
                s.charging = true
            case .full:
                s.ac_online = true
                s.charging = false
            default:
                s.ac_online = false
                s.charging = false
            }
            s.voltage_mv = 3700 + Int32(level * 650)   // nominal Li-ion curve
            s.temperature_decic = Self.temperatureDeciC(ProcessInfo.processInfo.thermalState)
            state = s
        }
        lock.lock()
        cached = state
        lock.unlock()
    }

    static func temperatureDeciC(_ t: ProcessInfo.ThermalState) -> Int32 {
        switch t {
        case .nominal: return 270
        case .fair: return 350
        case .serious: return 420
        case .critical: return 480
        @unknown default: return 300
        }
    }
}
