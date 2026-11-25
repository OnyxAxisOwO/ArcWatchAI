import SwiftUI

struct PhoneChat: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var showingHistory = false
    @FocusState private var composing: Bool
    let manageProviders: () -> Void

    var body: some View {
        Group {
            if store.messages.isEmpty {
                emptyChat
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("Arc Watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    composing = false
                    showingHistory = true
                } label: {
                    Label("历史对话", systemImage: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.newChat()
                    draft = ""
                    composing = store.selectedModel != nil
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            PhoneHistory { draft = "" }
        }
        .alert("对话提示", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var emptyChat: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ArcMark()
                        .foregroundStyle(store.tint.color)
                        .frame(width: 66, height: 66)
                        .accessibilityHidden(true)
                        .padding(.bottom, 28)
                    Text(store.selectedModel == nil ? "开始第一次对话" : "想聊点什么？")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    if store.selectedModel == nil {
                        Text("添加服务商和模型，就能在 iPhone 和 Apple Watch 上与 AI 对话。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                        Button(action: manageProviders) {
                            Label(store.providers.isEmpty ? "添加服务商" : "管理服务商", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .padding(.top, 22)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: 610, alignment: .leading)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(store.messages) { message in
                        if message.role == .user {
                            Text(verbatim: message.text)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(store.tint.color.opacity(0.17), in: UnevenRoundedRectangle(
                                    topLeadingRadius: 20, bottomLeadingRadius: 20,
                                    bottomTrailingRadius: 6, topTrailingRadius: 20
                                ))
                                .padding(.leading, 40)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel("你，\(message.text)")
                        } else {
                            MarkdownMessage(text: message.text, enabled: store.markdownEnabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if store.isSending && store.messages.last?.role == .user {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在回复…").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: 740)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.messages.last?.id) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("输入消息…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .padding(.horizontal, 6)
                .padding(.top, 6)
            HStack(spacing: 2) {
                modelMenu
                Spacer(minLength: 0)
                toolButton("联网搜索", symbol: "globe", value: $store.searchEnabled)
                toolButton("思考", symbol: "lightbulb", value: $store.thinkingEnabled)
                Button {
                    if store.isSending {
                        store.cancel()
                    } else {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            await store.send(text) {
                                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                                    draft = ""
                                    composing = false
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 33, height: 33)
                        .foregroundStyle(.background)
                        .background(canSend ? Color.primary : Color.secondary.opacity(0.45), in: Circle())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isSending ? "停止回复" : "发送")
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 2)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 23))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .frame(maxWidth: 740)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var canSend: Bool {
        store.isSending || (store.selectedModel != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(store.providers) { provider in
                if !provider.models.isEmpty {
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Button {
                                store.select(providerID: provider.id, modelID: model.id)
                            } label: {
                                if store.selectedProviderID == provider.id && store.selectedModelID == model.id {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    }
                }
            }
            Button(action: manageProviders) {
                Label("管理服务商", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.selectedModel?.name ?? "选择模型").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
        }
        .disabled(store.isSending)
    }

    private func toolButton(_ title: String, symbol: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(value.wrappedValue ? .semibold : .regular))
                .foregroundStyle(value.wrappedValue ? store.tint.color : .secondary)
                .frame(width: 33, height: 33)
                .background(value.wrappedValue ? store.tint.color.opacity(0.14) : .clear, in: Circle())
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value.wrappedValue ? "已开启" : "已关闭")
    }
}

private struct PhoneHistory: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var removal: Conversation?
    let didSwitch: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    store.newChat()
                    didSwitch()
                    dismiss()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
                if store.conversations.isEmpty {
                    Text("发送第一条消息后，对话会出现在这里。").foregroundStyle(.secondary)
                } else {
                    ForEach(store.conversations) { conversation in
                        Button {
                            store.open(conversation)
                            didSwitch()
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title).lineLimit(2).foregroundStyle(.primary)
                                Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .swipeActions {
                            Button(role: .destructive) { removal = conversation } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史对话")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("删除这段对话？", isPresented: Binding(
                get: { removal != nil }, set: { if !$0 { removal = nil } }
            ), titleVisibility: .visible, presenting: removal) { conversation in
                Button("删除对话", role: .destructive) { store.delete(conversation) }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
