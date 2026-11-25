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
    case history, settings, models
    var id: Self { self }
}

struct WatchChatView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panel: WatchPanel?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            actionBar
                .frame(maxWidth: 168)
                .padding(.horizontal, 7)
                .padding(.top, 5)
                .zIndex(1)
            if store.messages.isEmpty { emptyChat } else { transcript }
            composer
        }
        .padding(.horizontal, 5)
        .ignoresSafeArea(.container, edges: .top)
        // watchOS exposes the clock preference through this underscored SwiftUI modifier.
        ._statusBarHidden(panel == nil)
        .watchCanvas(store)
        .sheet(item: $panel) { destination in
            NavigationStack {
                switch destination {
                case .history:
                    WatchHistory {
                        draft = ""
                        panel = nil
                    }
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

    private var actionBar: some View {
        HStack(spacing: 6) {
            barButton("历史对话", symbol: "clock.arrow.circlepath") { panel = .history }
                .frame(width: 34)
                .background {
                    if #available(watchOS 26, *) {
                        Color.clear.frame(width: 26, height: 26)
                            .glassEffect(.regular.interactive(), in: .circle)
                    } else {
                        Circle().fill(.regularMaterial).frame(width: 26, height: 26)
                    }
                }

            HStack(spacing: 0) {
                barButton("联网搜索", symbol: "globe", selected: store.searchEnabled) { store.searchEnabled.toggle() }
                barButton("思考", symbol: "lightbulb", selected: store.thinkingEnabled) { store.thinkingEnabled.toggle() }
                barButton("设置", symbol: "gearshape") { panel = .settings }
            }
            .padding(.horizontal, 3)
            .background {
                Color.clear.frame(height: 26).watchBarSurface()
            }
        }
    }

    private func barButton(_ title: String, symbol: String, selected: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected == true ? store.watchAccent : .primary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected.map { $0 ? "已开启" : "已关闭" } ?? "")
        .accessibilityAddTraits(selected == true ? .isSelected : [])
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
        .clipped()
        .contentShape(Rectangle())
    }

    private var composer: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 0) {
            Text(verbatim: draft.isEmpty ? "输入消息" : draft)
                .font(.footnote)
                .foregroundStyle(draft.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .accessibilityHidden(true)
                .overlay {
                    // Keep the bound system editor and its draft, while the shared bar draws the field.
                    TextField("输入消息", text: $draft)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            Rectangle().blendMode(.destinationOut).allowsHitTesting(false)
                        }
                        .compositingGroup()
                        .contentShape(Rectangle())
                        .accessibilityLabel("输入消息")
                }
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
                    .font(.system(size: store.isSending ? 11 : 14, weight: .bold))
                    .foregroundStyle(store.isSending || canSend ? store.watchAccent : Color.secondary)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .disabled(!store.isSending && !canSend)
            .accessibilityLabel(store.isSending ? "停止回复" : "发送消息")
        }
        .buttonStyle(.plain)
        .frame(height: 32)
        .background { Color.clear.frame(height: 28).watchBarSurface() }
        .padding(.horizontal, 3)
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

private extension View {
    @ViewBuilder
    func watchBarSurface() -> some View {
        if #available(watchOS 26, *) { glassEffect(.regular.interactive(), in: .capsule) }
        else { background(.regularMaterial, in: Capsule()) }
    }
}
