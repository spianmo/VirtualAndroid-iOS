import CoreLocation
import Foundation

/// CoreLocation -> va_engine_location_update(). Authorization is requested
/// only when the guest turns GNSS on (location_set_enabled(true)).
final class LocationBridge: NSObject, CLLocationManagerDelegate {
    var sink: ((VaLocation) -> Void)?

    private var manager: CLLocationManager?
    private var wanted = false
    private var updates: UInt64 = 0
    private var lastError: String?

    /// Called from engine threads.
    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            wanted = enabled
            if enabled {
                let m = manager ?? makeManager()
                switch m.authorizationStatus {
                case .notDetermined:
                    m.requestWhenInUseAuthorization()   // starts in the delegate callback
                case .authorizedAlways, .authorizedWhenInUse:
                    m.startUpdatingLocation()
                default:
                    lastError = "denied"
                }
            } else {
                manager?.stopUpdatingLocation()
            }
        }
    }

    var status: String {
        "GNSS: \(wanted ? "on" : "off") fixes=\(updates)\(lastError.map { " (\($0))" } ?? "")"
    }

    private func makeManager() -> CLLocationManager {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = kCLDistanceFilterNone
        m.pausesLocationUpdatesAutomatically = false
        m.activityType = .other
        manager = m
        return m
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard wanted else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            lastError = nil
            manager.startUpdatingLocation()
        case .denied, .restricted:
            lastError = "denied"
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard wanted else { return }
        for l in locations {
            updates += 1
            sink?(Self.convert(l))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }

    static func convert(_ l: CLLocation) -> VaLocation {
        var v = VaLocation()
        v.latitude_deg = l.coordinate.latitude
        v.longitude_deg = l.coordinate.longitude
        v.altitude_m = l.verticalAccuracy >= 0 ? l.altitude : 0
        v.speed_mps = l.speed >= 0 ? Float(l.speed) : 0
        v.bearing_deg = l.course >= 0 ? Float(l.course) : 0
        v.horizontal_accuracy_m = l.horizontalAccuracy >= 0 ? Float(l.horizontalAccuracy) : 0
        v.unix_time_ms = Int64(l.timestamp.timeIntervalSince1970 * 1000)
        return v
    }
}
