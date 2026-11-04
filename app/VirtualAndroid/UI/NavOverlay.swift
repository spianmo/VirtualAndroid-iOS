import SwiftUI

/// Unobtrusive Android controls: a small handle on the trailing edge that
/// expands into back / home / recents / power / volume and a VM menu, and
/// collapses again after a few idle seconds.
struct NavOverlay: View {
    @EnvironmentObject private var vm: VMController
    @Binding var showDiagnostics: Bool
    @State private var expanded = false
    @State private var lastInteraction = Date()
    @State private var didApplyInitial = false

    var body: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                Group {
                    if expanded {
                        expandedPanel.transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        handle.transition(.opacity)
                    }
                }
                .animation(.spring(duration: 0.25), value: expanded)
                Spacer()
            }
        }
        .padding(.trailing, 6)
        .onAppear {
            if !didApplyInitial {
                didApplyInitial = true
                expanded = vm.navStartsExpanded
            }
        }
        .task(id: lastInteraction) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, !vm.navStartsExpanded { expanded = false }
        }
    }

    private func touched() { lastInteraction = Date() }

    private var handle: some View {
        Button {
            expanded = true
            touched()
        } label: {
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22, height: 64)
                .background(.black.opacity(0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Android controls")
    }

    private var expandedPanel: some View {
        VStack(spacing: 4) {
            KeyButton(symbol: "chevron.backward", label: "Back", code: LinuxKeymap.back, send: send)
            KeyButton(symbol: "circle", label: "Home", code: LinuxKeymap.home, send: send)
            KeyButton(symbol: "square", label: "Recents", code: LinuxKeymap.appSelect, send: send)
            Divider().frame(width: 28).overlay(.white.opacity(0.3))
            KeyButton(symbol: "power", label: "Power", code: LinuxKeymap.power, send: send)
            KeyButton(symbol: "speaker.plus", label: "Volume up", code: LinuxKeymap.volumeUp, send: send)
            KeyButton(symbol: "speaker.minus", label: "Volume down", code: LinuxKeymap.volumeDown, send: send)
            Divider().frame(width: 28).overlay(.white.opacity(0.3))
            vmMenu
            Button {
                expanded = false
            } label: {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .accessibilityLabel("Hide Android controls")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private var vmMenu: some View {
        Menu {
            if vm.phase == .paused {
                Button("Resume", systemImage: "play.fill") { vm.resume() }
            } else {
                Button("Pause", systemImage: "pause.fill") { vm.pause() }
            }
            Button("Paste iOS clipboard into Android", systemImage: "doc.on.clipboard") { vm.pasteHostClipboard() }
            Button("Hold power (power menu)", systemImage: "power.circle") { vm.tapKey(LinuxKeymap.power, holdSeconds: 1.2) }
            Picker("Rotation", selection: $vm.rotationMode) {
                ForEach(DisplayRotationMode.allCases) { Text($0.label).tag($0) }
            }
            Button("Cold boot (discard snapshot)", systemImage: "arrow.counterclockwise") { vm.coldBootNow() }
            Button("Diagnostics", systemImage: "waveform.path.ecg") { showDiagnostics = true }
            Button("Hide controls", systemImage: "eye.slash") { vm.showNavControls = false }
            Divider()
            Button("Shut down", systemImage: "power", role: .destructive) { vm.shutdown() }
            Button("Force stop", systemImage: "xmark.octagon", role: .destructive) { vm.forceStop() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white.opacity(0.9))
        .simultaneousGesture(TapGesture().onEnded { touched() })
        .accessibilityLabel("Virtual machine menu")
    }

    private func send(_ code: UInt32, _ down: Bool) {
        touched()
        vm.sendKey(code, down: down)
    }
}

/// Sends key down on touch-down and key up on release (so long-press works).
struct KeyButton: View {
    let symbol: String
    let label: String
    let code: UInt32
    let send: (UInt32, Bool) -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white.opacity(pressed ? 1 : 0.85))
            .frame(width: 44, height: 38)
            .background(pressed ? Color.white.opacity(0.25) : .clear, in: Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            send(code, true)
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        send(code, false)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("va-key-\(code)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                send(code, true)
                send(code, false)
            }
    }
}
