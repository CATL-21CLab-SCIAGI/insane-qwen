import SwiftUI

@main
struct EmbryoApp: App {
    @State private var store = EmbryoStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).tint(EmbryoStyle.green)
                .onChange(of: phase) { _, phase in
                    if phase == .background { store.cancelForBackground() }
                }
        }
    }
}

struct RootView: View {
    @Environment(EmbryoStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.isDemo {
                Text("OFFLINE SAMPLE · no requests sent").font(.caption.weight(.semibold)).padding(8).frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.18)).accessibilityIdentifier("demo.badge")
            } else if let error = store.persistenceError {
                Text(error).font(.caption).padding(8).frame(maxWidth: .infinity).background(Color.orange.opacity(0.18))
            }
            TabView(selection: $store.selectedTab) {
                PlaygroundView().tabItem { Label("Playground", systemImage: "sparkles") }.tag(0).accessibilityIdentifier("playground.tab")
                HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(1).accessibilityIdentifier("history.tab")
                ConnectionView().tabItem { Label("Connection", systemImage: "network") }.tag(2).accessibilityIdentifier("settings.tab")
            }
        }
        .alert("Couldn’t complete action", isPresented: Binding(get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
            Button("OK") { store.actionError = nil }
        } message: { Text(store.actionError ?? "") }
        .task { await store.checkConnection(); store.runDevelopmentSmokeIfRequested() }
    }
}

enum EmbryoStyle {
    static let green = Color(red: 0.12, green: 0.40, blue: 0.34)
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let ink = Color.primary
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct CapsuleLabel: View {
    var text: String
    var color: Color = EmbryoStyle.green
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.10), in: Capsule())
    }
}
