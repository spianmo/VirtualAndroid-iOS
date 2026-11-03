import SwiftUI

/// Bridge status, stub-engine bridge exercisers and the engine log.
struct DiagnosticsView: View {
    @EnvironmentObject private var vm: VMController
    @State private var stub = StubDiagnosticsState()

    var body: some View {
        List {
            Section("Platform bridges") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.host.statusLines(), id: \.self) { Text($0) }
                        Text("Display: \(vm.displayView.framesDrawn) frames drawn, rotation \(vm.displayView.quarterTurns * 90)°")
                    }
                    .font(.caption.monospaced())
                }
            }

            if let diag = vm.stubDiagnostics {
                Section {
                    Toggle("Guest enables GNSS", isOn: binding(\.gnss, diag))
                    Toggle("Guest opens camera 0", isOn: binding(\.camera, diag))
                    Toggle("Guest records microphone", isOn: binding(\.mic, diag))
                    Toggle("Guest plays 440 Hz tone", isOn: binding(\.tone, diag))
                    Toggle("Guest enables all sensors", isOn: binding(\.allSensors, diag))
                    Button("Guest vibrates 300 ms") { diag.diagnosticVibrate() }
                    Button("Guest copies text") { diag.diagnosticGuestCopy() }
                    Button("Paste iOS clipboard into guest") { vm.pasteHostClipboard() }
                } header: {
                    Text("Stub engine: simulate guest requests")
                } footer: {
                    Text("These go through the same VaHostCallbacks the real engine uses; permission prompts appear only here, when a feature is first enabled.")
                }
                .onAppear { stub = diag.diagnostics }
            }

            Section("Log") {
                ForEach(Array(vm.logLines.suffix(150).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ keyPath: WritableKeyPath<StubDiagnosticsState, Bool>, _ diag: StubDiagnostics) -> Binding<Bool> {
        Binding(get: { stub[keyPath: keyPath] }, set: { value in
            stub[keyPath: keyPath] = value
            diag.setDiagnostics(stub)
        })
    }
}
