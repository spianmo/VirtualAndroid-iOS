import SwiftUI

@main
struct VirtualAndroidApp: App {
    @StateObject private var vm = VMController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            vm.scenePhaseChanged(newPhase)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var vm: VMController

    var body: some View {
        Group {
            if vm.isVMActive {
                VMScreen()
            } else {
                HomeView()
            }
        }
        .task { vm.launchIfNeeded() }
    }
}
