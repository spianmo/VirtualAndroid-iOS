import SwiftUI

/// Full-screen guest display with boot/paused indicators and the nav overlay.
struct VMScreen: View {
    @EnvironmentObject private var vm: VMController
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DisplayContainer(view: vm.displayView)
                .ignoresSafeArea()

            VStack {
                if vm.phase == .booting {
                    BootBadge(progress: vm.bootProgress, message: vm.bootMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.3), value: vm.phase)

            if vm.phase == .paused {
                Button {
                    vm.resume()
                } label: {
                    Label("Paused — tap to resume", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if vm.phase == .stopping {
                ProgressView("Shutting down…")
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }

            if vm.showNavControls {
                NavOverlay(showDiagnostics: $showDiagnostics)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack { DiagnosticsView() }
                .presentationDetents([.medium, .large])
        }
    }
}

private struct BootBadge: View {
    let progress: Double
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Booting Android · \(Int(progress * 100))%").font(.caption.bold())
                if !message.isEmpty {
                    Text(message).font(.caption2.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: 360)
    }
}
