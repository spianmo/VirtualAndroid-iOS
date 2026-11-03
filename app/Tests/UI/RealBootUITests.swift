import XCTest

/// End-to-end check of the real engine in the simulator: boots Android inside
/// the app, then drives it with *real* UIKit touches (XCUITest taps on the
/// Metal display view) and the on-screen overlay buttons.
///
///   xcodebuild test -project app/VirtualAndroid.xcodeproj -scheme VirtualAndroid \
///     -destination 'platform=iOS Simulator,id=<udid>' -only-testing:VirtualAndroidUITests
///
/// Progress lines start with "VA-UITEST" (seconds since app launch), so an
/// outside script can take `simctl io screenshot`s and cross-check with adb.
/// Env (prefix TEST_RUNNER_ when passed through xcodebuild):
///   VA_TAP1 / VA_TAP2   guest points "x,y" (0..1) to tap (default Gallery, Phone)
///   VA_BOOT_TIMEOUT     seconds (default 900)
final class RealBootUITests: XCTestCase {
    private var start = Date()

    private func mark(_ s: String) {
        print(String(format: "VA-UITEST %7.1fs %@", Date().timeIntervalSince(start), s))
    }

    /// Marks a checkpoint and holds still so an outside script can take a
    /// screenshot and query adb before the next action.
    private func checkpoint(_ s: String) {
        mark(s)
        pause(Double(ProcessInfo.processInfo.environment["VA_HOLD"] ?? "") ?? 8)
    }

    private func guestPoint(_ env: String, default d: CGPoint) -> CGPoint {
        let v = ProcessInfo.processInfo.environment[env]?.split(separator: ",").compactMap { Double($0) } ?? []
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : d
    }

    /// Same letterbox as DisplayGeometry (portrait, 1080x2340 panel).
    private func tapGuest(_ app: XCUIApplication, _ g: CGPoint, label: String) {
        let frame = app.windows.firstMatch.frame
        let content = CGSize(width: 1080, height: 2340)
        let scale = min(frame.width / content.width, frame.height / content.height)
        let w = content.width * scale, h = content.height * scale
        let x = (frame.width - w) / 2 + g.x * w
        let y = (frame.height - h) / 2 + g.y * h
        mark("tap \(label) guest (\(g.x), \(g.y)) view (\(Int(x)), \(Int(y)))")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func testBootToHomeAndInteract() throws {
        let env = ProcessInfo.processInfo.environment
        let bootTimeout = Double(env["VA_BOOT_TIMEOUT"] ?? "") ?? 900
        let app = XCUIApplication()
        app.launchArguments = ["-VAEngine", "qemu", "-VAAutoBoot", "YES", "-VANavExpanded", "YES",
                               "-VAForceOrientation", "portrait"]
        start = Date()
        app.launch()
        mark("launched")

        let phase = app.staticTexts["va-phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: 120), "VM screen did not appear")
        mark("vm screen: \(phase.value as? String ?? "?")")

        let running = NSPredicate(format: "value == 'running'")
        let exp = expectation(for: running, evaluatedWith: phase)
        let result = XCTWaiter().wait(for: [exp], timeout: bootTimeout)
        XCTAssertEqual(result, .completed, "guest did not report BOOT_COMPLETED")
        mark("boot completed")

        pause(Double(env["VA_SETTLE"] ?? "") ?? 25)   // launcher draws after boot_completed
        checkpoint("home settled")

        tapGuest(app, guestPoint("VA_TAP1", default: CGPoint(x: 0.308, y: 0.740)), label: "icon1")
        pause(20)
        checkpoint("after icon1")

        let home = app.descendants(matching: .any)["va-key-172"]   // overlay HOME (KEY_HOMEPAGE)
        XCTAssertTrue(home.waitForExistence(timeout: 10), "overlay Home button missing")
        mark("overlay HOME")
        home.tap()
        pause(10)
        checkpoint("after HOME")

        tapGuest(app, guestPoint("VA_TAP2", default: CGPoint(x: 0.117, y: 0.900)), label: "icon2")
        pause(20)
        checkpoint("after icon2")

        let back = app.descendants(matching: .any)["va-key-158"]   // overlay BACK
        XCTAssertTrue(back.waitForExistence(timeout: 10), "overlay Back button missing")
        mark("overlay BACK")
        back.tap()
        pause(10)
        checkpoint("after BACK")

        // Stop the VM from the overlay menu: QMP quit -> qemu_main_loop returns
        // -> qemu_cleanup (libva_gfx teardown). The app itself must survive.
        let menu = app.descendants(matching: .any)["Virtual machine menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "overlay menu missing")
        menu.tap()
        let stop = app.buttons["Force stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Force stop missing")
        mark("force stop")
        stop.tap()
        let startButton = app.buttons["Start Android"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 60), "app did not return to the home view")
        mark("vm stopped, app alive: \(app.state == .runningForeground)")
        pause(5)
        XCTAssertEqual(app.state, .runningForeground, "app died after the VM stopped")
        mark("done")
    }
}
