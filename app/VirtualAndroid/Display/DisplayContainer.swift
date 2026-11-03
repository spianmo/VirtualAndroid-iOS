import SwiftUI
import UIKit

/// Hosts the controller's single MetalDisplayView instance in SwiftUI.
struct DisplayContainer: UIViewRepresentable {
    let view: MetalDisplayView
    var onInteraction: (() -> Void)?

    func makeUIView(context: Context) -> MetalDisplayView {
        view.onUserInteraction = onInteraction
        return view
    }

    func updateUIView(_ uiView: MetalDisplayView, context: Context) {
        uiView.onUserInteraction = onInteraction
    }
}
