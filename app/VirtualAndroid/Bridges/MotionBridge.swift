import CoreMotion
import Foundation
import simd

/// CoreMotion -> Android sensors.
///
/// Axis and unit mapping (see app/README.md, "Sensor mapping"):
///  * Both platforms use the same device-fixed axes: +x toward the right edge,
///    +y toward the top edge, +z out of the screen (right-handed).
///  * Accelerometer: iOS reports units of g and the *opposite* sign: an upright
///    phone reads y = -1 g, face-up on a table z = -1 g. Android reports the
///    specific force in m/s^2: upright y = +9.81, face-up z = +9.81.
///    => android = -ios * 9.80665. The same holds for gravity
///    (CMDeviceMotion.gravity) and linear acceleration (userAcceleration).
///  * Gyroscope: rad/s, right-hand rule about the same axes => unchanged
///    (bias-corrected CMDeviceMotion.rotationRate when available).
///  * Magnetic field: uT, same axes => unchanged (calibrated
///    CMDeviceMotion.magneticField when its accuracy is known, else raw).
///  * Pressure: CMAltimeter reports kPa => hPa = kPa * 10.
///  * Rotation vector: CoreMotion attitude is relative to X = magnetic north,
///    Z = up (so Y = west); Android's world frame is X = east, Y = north,
///    Z = up. q_android = q_z(+90 deg) * q_ios(device->world). Which way
///    CoreMotion's quaternion points is checked at runtime against gravity.
///  * Orientation (legacy, degrees): derived from the Android rotation matrix
///    like SensorManager.getOrientation(); azimuth wrapped to 0..360.
/// On the simulator (no motion hardware) acceleration and gravity are
/// synthesized from the current display rotation, like the Android emulator's
/// virtual sensors, so the guest's auto-rotate works.
final class MotionBridge {
    static let standardGravity: Float = 9.80665

    var sink: ((VaSensorType, [Float], Int64) -> Void)?

    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "va.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()
    private var enabled: [UInt32: UInt32] = [:]          // VaSensorType.rawValue -> delay ms
    private var simulatedRotationDegrees = 0
    private var synthTimer: DispatchSourceTimer?
    private var altimeterRunning = false
    private var samples: [UInt32: UInt64] = [:]

    private static let deviceMotionTypes: [VaSensorType] = [
        VA_SENSOR_GYROSCOPE, VA_SENSOR_MAGNETIC_FIELD, VA_SENSOR_ORIENTATION, VA_SENSOR_GRAVITY,
        VA_SENSOR_LINEAR_ACCELERATION, VA_SENSOR_ROTATION_VECTOR,
    ]

    var hasRealAccelerometer: Bool { manager.isAccelerometerAvailable }

    /// Bitmask (1 << VaSensorType) of what we can provide.
    lazy var availableMask: UInt32 = {
        var mask: UInt32 = 0
        func add(_ t: VaSensorType) { mask |= 1 << t.rawValue }
        if manager.isAccelerometerAvailable {
            add(VA_SENSOR_ACCELERATION)
        } else {
            add(VA_SENSOR_ACCELERATION)   // synthesized from display rotation
            add(VA_SENSOR_GRAVITY)
        }
        if manager.isGyroAvailable { add(VA_SENSOR_GYROSCOPE) }
        if manager.isMagnetometerAvailable { add(VA_SENSOR_MAGNETIC_FIELD) }
        if manager.isDeviceMotionAvailable {
            add(VA_SENSOR_GRAVITY)
            add(VA_SENSOR_LINEAR_ACCELERATION)
            add(VA_SENSOR_ROTATION_VECTOR)
            add(VA_SENSOR_ORIENTATION)
        }
        if CMAltimeter.isRelativeAltitudeAvailable() { add(VA_SENSOR_PRESSURE) }
        return mask
    }()

    /// Android surface rotation of the device (0/90/180/270, CCW), used for
    /// the simulated accelerometer when there is no motion hardware.
    func setSimulatedRotation(_ degrees: Int) {
        lock.lock()
        simulatedRotationDegrees = ((degrees % 360) + 360) % 360
        lock.unlock()
    }

    /// Called from engine threads.
    func setEnabled(_ type: VaSensorType, enabled on: Bool, delayMs: UInt32) {
        guard type.rawValue < VA_SENSOR_COUNT.rawValue else { return }
        lock.lock()
        if on {
            enabled[type.rawValue] = max(5, delayMs == 0 ? 10 : delayMs)
        } else {
            enabled.removeValue(forKey: type.rawValue)
        }
        lock.unlock()
        queue.addOperation { [weak self] in self?.reconfigure() }
    }

    func stopAll() {
        lock.lock()
        enabled.removeAll()
        lock.unlock()
        queue.addOperation { [weak self] in self?.reconfigure() }
    }

    var status: String {
        lock.lock()
        defer { lock.unlock() }
        if enabled.isEmpty { return "Sensors: idle" }
        let names = enabled.keys.sorted().map { key -> String in
            "\(Self.name(VaSensorType(rawValue: key))) \(1000 / max(1, enabled[key]!))Hz n=\(samples[key] ?? 0)"
        }
        return "Sensors: " + names.joined(separator: ", ")
    }

    static func name(_ t: VaSensorType) -> String {
        switch t {
        case VA_SENSOR_ACCELERATION: return "accel"
        case VA_SENSOR_GYROSCOPE: return "gyro"
        case VA_SENSOR_MAGNETIC_FIELD: return "mag"
        case VA_SENSOR_ORIENTATION: return "orient"
        case VA_SENSOR_TEMPERATURE: return "temp"
        case VA_SENSOR_PROXIMITY: return "prox"
        case VA_SENSOR_LIGHT: return "light"
        case VA_SENSOR_PRESSURE: return "pressure"
        case VA_SENSOR_HUMIDITY: return "humidity"
        case VA_SENSOR_GRAVITY: return "gravity"
        case VA_SENSOR_LINEAR_ACCELERATION: return "linear"
        case VA_SENSOR_ROTATION_VECTOR: return "rotvec"
        default: return "sensor\(t.rawValue)"
        }
    }

    // MARK: - Configuration (motion queue)

    private func snapshot() -> [UInt32: UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    private func isOn(_ t: VaSensorType, _ s: [UInt32: UInt32]) -> Bool { s[t.rawValue] != nil }

    private func minDelay(_ types: [VaSensorType], _ s: [UInt32: UInt32]) -> UInt32? {
        types.compactMap { s[$0.rawValue] }.min()
    }

    private func reconfigure() {
        let s = snapshot()

        // Accelerometer.
        if isOn(VA_SENSOR_ACCELERATION, s), manager.isAccelerometerAvailable {
            manager.accelerometerUpdateInterval = Double(s[VA_SENSOR_ACCELERATION.rawValue]!) / 1000
            if !manager.isAccelerometerActive {
                manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                    guard let self, let a = data?.acceleration else { return }
                    let g = Self.standardGravity
                    self.emit(VA_SENSOR_ACCELERATION, [Float(-a.x) * g, Float(-a.y) * g, Float(-a.z) * g],
                              ts: data!.timestamp)
                }
            }
        } else if manager.isAccelerometerActive {
            manager.stopAccelerometerUpdates()
        }

        // Device motion (fused): gyro, mag, gravity, linear, rotation vector, orientation.
        let dmDelay = minDelay(Self.deviceMotionTypes, s)
        if let dmDelay, manager.isDeviceMotionAvailable {
            manager.deviceMotionUpdateInterval = Double(dmDelay) / 1000
            if !manager.isDeviceMotionActive {
                let frames = CMMotionManager.availableAttitudeReferenceFrames()
                let frame: CMAttitudeReferenceFrame = frames.contains(.xMagneticNorthZVertical)
                    ? .xMagneticNorthZVertical : .xArbitraryZVertical
                manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
                    guard let self, let motion else { return }
                    self.handleDeviceMotion(motion)
                }
            }
        } else if manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }

        // Raw gyro only when there is no device motion.
        if isOn(VA_SENSOR_GYROSCOPE, s), !manager.isDeviceMotionAvailable, manager.isGyroAvailable {
            manager.gyroUpdateInterval = Double(s[VA_SENSOR_GYROSCOPE.rawValue]!) / 1000
            if !manager.isGyroActive {
                manager.startGyroUpdates(to: queue) { [weak self] data, _ in
                    guard let self, let r = data?.rotationRate else { return }
                    self.emit(VA_SENSOR_GYROSCOPE, [Float(r.x), Float(r.y), Float(r.z)], ts: data!.timestamp)
                }
            }
        } else if manager.isGyroActive {
            manager.stopGyroUpdates()
        }

        // Raw magnetometer as fallback while the fused field is uncalibrated.
        if isOn(VA_SENSOR_MAGNETIC_FIELD, s), manager.isMagnetometerAvailable {
            manager.magnetometerUpdateInterval = Double(s[VA_SENSOR_MAGNETIC_FIELD.rawValue]!) / 1000
            if !manager.isMagnetometerActive {
                manager.startMagnetometerUpdates(to: queue) { [weak self] data, _ in
                    guard let self, let f = data?.magneticField else { return }
                    // Prefer the calibrated field from device motion when it is valid.
                    if let dm = self.manager.deviceMotion, dm.magneticField.accuracy != .uncalibrated {
                        return
                    }
                    self.emit(VA_SENSOR_MAGNETIC_FIELD, [Float(f.x), Float(f.y), Float(f.z)], ts: data!.timestamp)
                }
            }
        } else if manager.isMagnetometerActive {
            manager.stopMagnetometerUpdates()
        }

        // Barometer.
        if isOn(VA_SENSOR_PRESSURE, s), CMAltimeter.isRelativeAltitudeAvailable() {
            if !altimeterRunning {
                altimeterRunning = true
                altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
                    guard let self, let data else { return }
                    self.emit(VA_SENSOR_PRESSURE, [data.pressure.floatValue * 10], ts: data.timestamp)
                }
            }
        } else if altimeterRunning {
            altimeterRunning = false
            altimeter.stopRelativeAltitudeUpdates()
        }

        // Simulator: synthesize acceleration/gravity from display rotation.
        let synthTypes = manager.isAccelerometerAvailable ? [] : [VA_SENSOR_ACCELERATION, VA_SENSOR_GRAVITY]
        if let delay = minDelay(synthTypes, s) {
            synthTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now(), repeating: .milliseconds(Int(max(delay, 20))))
            timer.setEventHandler { [weak self] in self?.emitSynthetic() }
            timer.resume()
            synthTimer = timer
        } else {
            synthTimer?.cancel()
            synthTimer = nil
        }
    }

    private func emitSynthetic() {
        lock.lock()
        let rotation = simulatedRotationDegrees
        let s = enabled
        lock.unlock()
        let g = Self.standardGravity
        // Up direction expressed in device axes for each Android surface rotation.
        let v: [Float]
        switch rotation {
        case 90: v = [g, 0, 0]       // device turned CCW: right edge up
        case 180: v = [0, -g, 0]
        case 270: v = [-g, 0, 0]     // device turned CW: left edge up
        default: v = [0, g, 0]       // upright portrait
        }
        let now = hostMonotonicNs()
        if s[VA_SENSOR_ACCELERATION.rawValue] != nil { emitNs(VA_SENSOR_ACCELERATION, v, ns: now) }
        if s[VA_SENSOR_GRAVITY.rawValue] != nil { emitNs(VA_SENSOR_GRAVITY, v, ns: now) }
    }

    private func handleDeviceMotion(_ m: CMDeviceMotion) {
        let s = snapshot()
        let ts = m.timestamp
        let g = Self.standardGravity
        if isOn(VA_SENSOR_GYROSCOPE, s) {
            let r = m.rotationRate
            emit(VA_SENSOR_GYROSCOPE, [Float(r.x), Float(r.y), Float(r.z)], ts: ts)
        }
        if isOn(VA_SENSOR_MAGNETIC_FIELD, s), m.magneticField.accuracy != .uncalibrated {
            let f = m.magneticField.field
            emit(VA_SENSOR_MAGNETIC_FIELD, [Float(f.x), Float(f.y), Float(f.z)], ts: ts)
        }
        if isOn(VA_SENSOR_GRAVITY, s) {
            emit(VA_SENSOR_GRAVITY, [Float(-m.gravity.x) * g, Float(-m.gravity.y) * g, Float(-m.gravity.z) * g], ts: ts)
        }
        if isOn(VA_SENSOR_LINEAR_ACCELERATION, s) {
            let u = m.userAcceleration
            emit(VA_SENSOR_LINEAR_ACCELERATION, [Float(-u.x) * g, Float(-u.y) * g, Float(-u.z) * g], ts: ts)
        }
        if isOn(VA_SENSOR_ROTATION_VECTOR, s) || isOn(VA_SENSOR_ORIENTATION, s) {
            let q = Self.androidRotation(attitude: m.attitude.quaternion, gravity: m.gravity)
            if isOn(VA_SENSOR_ROTATION_VECTOR, s) {
                emit(VA_SENSOR_ROTATION_VECTOR, [q.imag.x, q.imag.y, q.imag.z, q.real], ts: ts)
            }
            if isOn(VA_SENSOR_ORIENTATION, s) {
                emit(VA_SENSOR_ORIENTATION, Self.orientationDegrees(q), ts: ts)
            }
        }
    }

    /// Device->world (ENU) quaternion in Android's convention.
    static func androidRotation(attitude a: CMQuaternion, gravity: CMAcceleration) -> simd_quatf {
        var q = simd_quatf(ix: Float(a.x), iy: Float(a.y), iz: Float(a.z), r: Float(a.w))
        // If q maps device->reference, the reference "up" axis in device
        // coordinates is the third row of its matrix; it must point against gravity.
        let m = simd_matrix3x3(q)            // columns
        let upInDevice = SIMD3<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z)
        let up = -SIMD3<Float>(Float(gravity.x), Float(gravity.y), Float(gravity.z))
        if simd_dot(upInDevice, up) < 0 {
            q = q.conjugate
        }
        let northWestUpToENU = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        var out = simd_normalize(northWestUpToENU * q)
        if out.real < 0 { out = simd_quatf(vector: -out.vector) }
        return out
    }

    /// Legacy TYPE_ORIENTATION: azimuth, pitch, roll in degrees.
    static func orientationDegrees(_ q: simd_quatf) -> [Float] {
        let m = simd_matrix3x3(q)            // v_world = m * v_device
        // Row-major accessors like Android's float[9] R.
        func r(_ row: Int, _ col: Int) -> Float { m[col][row] }
        let azimuth = atan2(r(0, 1), r(1, 1))
        let pitch = asin(max(-1, min(1, -r(2, 1))))
        let roll = atan2(-r(2, 0), r(2, 2))
        let deg: Float = 180 / .pi
        var az = azimuth * deg
        if az < 0 { az += 360 }
        return [az, pitch * deg, roll * deg]
    }

    // MARK: - Emit

    private func emit(_ type: VaSensorType, _ values: [Float], ts: TimeInterval) {
        emitNs(type, values, ns: Int64(ts * 1_000_000_000))
    }

    private func emitNs(_ type: VaSensorType, _ values: [Float], ns: Int64) {
        lock.lock()
        samples[type.rawValue, default: 0] += 1
        lock.unlock()
        sink?(type, values, ns)
    }
}
