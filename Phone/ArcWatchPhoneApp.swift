import SwiftUI

@main
struct ArcWatchPhoneApp: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            PhoneHome()
                .environmentObject(store)
                .tint(store.tint.color)
                .preferredColorScheme(store.appearance.colorScheme)
        }
    }
}

private enum PhoneTab: Hashable {
    case chat, providers, settings
}

private struct PhoneHome: View {
    @EnvironmentObject private var store: ChatStore
    @State private var tab: PhoneTab = .chat
    @State private var addingFirstProvider = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                PhoneChat {
                    tab = .providers
                    if store.providers.isEmpty { addingFirstProvider = true }
                }
            }
            .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            .tag(PhoneTab.chat)

            NavigationStack {
                PhoneProviders()
            }
            .tabItem { Label("服务商", systemImage: "square.stack.3d.up") }
            .tag(PhoneTab.providers)

            NavigationStack {
                PhoneSettings()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(PhoneTab.settings)
        }
        .sheet(isPresented: $addingFirstProvider) { ProviderEditor(existing: nil) }
    }
}
