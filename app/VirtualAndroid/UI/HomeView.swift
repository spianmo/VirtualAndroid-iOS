import SwiftUI
import UniformTypeIdentifiers

/// Start screen: image setup, engine choice, options, boot.
struct HomeView: View {
    @EnvironmentObject private var vm: VMController
    @State private var importing = false
    @State private var confirmReset = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Android 13").font(.largeTitle.bold())
                        Text("AOSP API 33 · arm64-v8a · 1080×2340 · 2 GB").font(.subheadline).foregroundStyle(.secondary)
                        Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Button {
                        vm.boot()
                    } label: {
                        Label(vm.resolvedEngineKind == .qemu ? "Start Android" : "Start stub engine",
                              systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.phase == .installing || vm.relaunchRequired ||
                              (vm.resolvedEngineKind == .qemu && !vm.imageInstalled))
                    if let err = vm.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                    if vm.relaunchRequired {
                        Button("Quit VirtualAndroid (reopen to cold boot)", role: .destructive) { vm.quitApp() }
                    }
                }

                Section {
                    if vm.phase == .installing {
                        VStack(alignment: .leading) {
                            ProgressView(value: vm.installProgress)
                            Text(vm.installMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if vm.imageInstalled {
                        Label("Image installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Image not installed", systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
                    }
                    if let pack = vm.packLocation, vm.phase != .installing {
                        Button("Install image pack from \(pack.deletingLastPathComponent().lastPathComponent)/\(pack.lastPathComponent)") {
                            vm.installImagePack(from: pack)
                        }
                    }
                    Button("Import image pack folder…") { importing = true }
                        .disabled(vm.phase == .installing)
                    if vm.imageInstalled {
                        Button("Reset Android data", role: .destructive) { confirmReset = true }
                        Button("Delete image", role: .destructive) { confirmDelete = true }
                    }
                } header: {
                    Text("System image")
                } footer: {
                    Text("An image pack holds kernel-ranchu, ramdisk.img, system.img, vendor.img, encryptionkey, userdata.qcow2 and cache.qcow2 (made on a Mac by app/scripts/make_userdata_qcow2.sh). Put it in Documents/ImagePack or import a folder.")
                }

                Section("Engine") {
                    Picker("Engine", selection: $vm.engineKind) {
                        ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Selected", value: vm.resolvedEngineKind.label)
                    Text(vm.engineSummary).font(.footnote).foregroundStyle(.secondary)
                }

                Section("Options") {
                    Toggle("Start automatically on launch", isOn: $vm.autoBoot)
                    Toggle("Fast resume (snapshot when leaving the app)", isOn: $vm.fastResume)
                    if !vm.engineSupportsSnapshots(vm.resolvedEngineKind) {
                        Text("This engine build has no snapshot support yet; cold boots only.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let info = vm.snapshotInfo {
                        LabeledContent("Snapshot", value: info).font(.footnote)
                        Button("Discard snapshot / cold boot next time", role: .destructive) { vm.discardSnapshot() }
                    }
                    if let t = vm.restoreTimings {
                        LabeledContent("Last restore", value: t).font(.footnote)
                    }
                    Picker("Rotation", selection: $vm.rotationMode) {
                        ForEach(DisplayRotationMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Sync iOS clipboard to Android on activate", isOn: $vm.clipboardAutoSync)
                    Toggle("Keep running in background", isOn: $vm.keepRunningInBackground)
                    Toggle("On-screen Android controls", isOn: $vm.showNavControls)
                }

                Section {
                    NavigationLink("Diagnostics & logs") { DiagnosticsView() }
                }
            }
            .navigationTitle("VirtualAndroid")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.refreshImageState() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    vm.installImagePack(from: url, securityScoped: true)
                }
            }
            .confirmationDialog("Erase all Android data?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { vm.resetAndroidData() }
            }
            .confirmationDialog("Delete the installed image?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { vm.deleteImage() }
            }
        }
    }

    private var statusLine: String {
        switch vm.phase {
        case .stopped: return "Stopped" + (vm.bootSeconds.map { String(format: " · last boot %.1f s", $0) } ?? "")
        case .failed: return "Failed"
        case .installing: return "Installing image…"
        default: return "Ready"
        }
    }
}
