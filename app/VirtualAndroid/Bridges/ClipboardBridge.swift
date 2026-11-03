import Foundation
import UIKit

/// UIPasteboard <-> guest clipboard.
///  * guest -> iOS: always (writing does not prompt).
///  * iOS -> guest: reading another app's pasteboard shows the iOS paste
///    prompt, so it happens only on an explicit "Paste to Android" action, or
///    automatically on app activation when `autoSync` is enabled.
final class ClipboardBridge {
    var sink: ((String) -> Void)?
    var autoSync = false

    private var lastChangeCount = -1
    private var lastGuestText: String?
    private var observers: [NSObjectProtocol] = []
    private var toGuest = 0
    private var fromGuestCount = 0

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            guard let self, self.autoSync else { return }
            self.pushHostClipboard(force: false)
        })
    }

    /// Engine thread.
    func fromGuest(_ text: String) {
        DispatchQueue.main.async { [self] in
            fromGuestCount += 1
            lastGuestText = text
            UIPasteboard.general.string = text
            lastChangeCount = UIPasteboard.general.changeCount
        }
    }

    /// Main thread. Sends the iOS clipboard text to the guest.
    func pushHostClipboard(force: Bool) {
        let pb = UIPasteboard.general
        guard force || pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.hasStrings, let text = pb.string, text != lastGuestText || force else { return }
        toGuest += 1
        sink?(text)
    }

    var status: String { "Clipboard: guest->iOS \(fromGuestCount), iOS->guest \(toGuest)\(autoSync ? " (auto)" : "")" }
}
