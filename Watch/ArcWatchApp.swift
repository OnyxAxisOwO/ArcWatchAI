import SwiftUI

@main
struct ArcWatchApp: App {
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            WatchChatView()
                .environmentObject(store)
                .tint(store.watchAccent)
                .preferredColorScheme(store.appearance.colorScheme)
        }
    }
}

enum WatchPanel: String, Identifiable {
    case history, tools, settings, models
    var id: Self { self }
}

struct WatchChatView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panel: WatchPanel?
    @State private var draft = ""

    var body: some View {
        GeometryReader { geometry in
            let compactControls = geometry.size.width < 153
            VStack(spacing: 0) {
                toolbar(compact: compactControls)
                if store.messages.isEmpty {
                    emptyChat
                } else {
                    transcript
                }
                composer
            }
            .padding(.horizontal, 5)
        }
        .watchCanvas(store)
        .sheet(item: $panel) { destination in
            NavigationStack {
                switch destination {
                case .history:
                    WatchHistory {
                        draft = ""
                        panel = nil
                    }
                case .tools: WatchTools()
                case .settings: WatchSettings()
                case .models: WatchModels()
                }
            }
            .watchCanvas(store)
        }
        .alert("未能完成操作", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 0) {
            WatchToolButton(symbol: "clock.arrow.circlepath", title: "历史对话") {
                panel = .history
            }
            Spacer(minLength: 0)
            if compact {
                WatchToolButton(symbol: "slider.horizontal.3", title: "对话工具",
                                selected: store.searchEnabled || store.thinkingEnabled) {
                    panel = .tools
                }
            } else {
                WatchToolButton(symbol: "globe", title: "联网搜索", selected: store.searchEnabled) {
                    store.searchEnabled.toggle()
                }
                WatchToolButton(symbol: "lightbulb", title: "思考", selected: store.thinkingEnabled) {
                    store.thinkingEnabled.toggle()
                }
                WatchToolButton(symbol: "gearshape", title: "设置") {
                    panel = .settings
                }
            }
        }
    }

    private var emptyChat: some View {
        GeometryReader { geometry in
            VStack(spacing: 3) {
                if geometry.size.height >= 88 {
                    ArcMark().fill(store.watchAccent).frame(width: 29, height: 29)
                        .accessibilityHidden(true)
                    emptyTitle
                } else {
                    HStack(spacing: 5) {
                        ArcMark().fill(store.watchAccent).frame(width: 21, height: 21)
                            .accessibilityHidden(true)
                        emptyTitle
                    }
                }
                Button { panel = .models } label: {
                    HStack(spacing: 3) {
                        Text(store.selectedModel?.name ?? "在 iPhone 添加服务商")
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.selectedModel.map { "选择模型，当前为" + $0.name } ?? "查看 iPhone 配置方法")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyTitle: some View {
        Text("新对话").font(.system(.headline, design: .rounded, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    ForEach(store.messages) { message in
                        WatchMessage(message: message)
                            .id(message.id)
                    }
                    if store.isSending && store.messages.last?.role == .user {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(store.thinkingEnabled ? "正在思考…" : "正在回复…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                if let last = store.messages.last {
                    reader.scrollTo(last.id, anchor: .top)
                }
            }
            .onChange(of: store.messages.last?.id) { _, newID in
                guard let newID else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    reader.scrollTo(newID, anchor: .top)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 3) {
            TextField("输入消息", text: $draft)
                .font(.footnote)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(Capsule())
                .accessibilityLabel("输入消息")
            Button {
                if store.isSending {
                    store.cancel()
                } else if store.selectedModel == nil {
                    panel = .models
                } else {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task {
                        await store.send(text) { draft = "" }
                    }
                }
            } label: {
                Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                    .font(.system(size: store.isSending ? 13 : 17, weight: .bold))
                    .foregroundStyle(store.watchAccentInk)
                    .frame(width: 32, height: 32)
                    .background(store.watchAccent, in: Circle())
                    .frame(width: 38, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.isSending && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(store.isSending ? "停止回复" : "发送消息")
        }
        .padding(.horizontal, 3)
        .padding(.top, 2)
    }
}

private struct WatchMessage: View {
    @EnvironmentObject private var store: ChatStore
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            Text(verbatim: message.text)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(store.watchAccent.opacity(0.23), in:
                    UnevenRoundedRectangle(topLeadingRadius: 13, bottomLeadingRadius: 13,
                                           bottomTrailingRadius: 4, topTrailingRadius: 13))
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("你：" + message.text)
        } else {
            MarkdownMessage(text: message.text, enabled: store.markdownEnabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WatchToolButton: View {
    @EnvironmentObject private var store: ChatStore
    let symbol: String
    let title: String
    var selected: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected == true ? store.watchAccent : Color.primary)
                .frame(width: 26, height: 26)
                .background(selected == true ? store.watchAccent.opacity(0.22) : Color.primary.opacity(0.09),
                            in: Circle())
                .frame(width: 35, height: 35)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected.map { $0 ? "已开启" : "已关闭" } ?? "")
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}
