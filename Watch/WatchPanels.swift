import SwiftUI

extension ChatStore {
    private var watchAccentRGB: (red: Double, green: Double, blue: Double) {
        let dark = appearance.colorScheme != .light
        let destination: Double = dark ? 1 : 0
        let rgb = tint.hex
        var red = Double(rgb >> 16 & 255) / 255
        var green = Double(rgb >> 8 & 255) / 255
        var blue = Double(rgb & 255) / 255
        // Even a pure black or white custom tint must remain visible on the chosen canvas.
        for _ in 0..<12 {
            let luminance = watchLuminance(red: red, green: green, blue: blue)
            let contrast = dark ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
            if contrast >= 4.8 { break }
            red += (destination - red) * 0.14
            green += (destination - green) * 0.14
            blue += (destination - blue) * 0.14
        }
        return (red, green, blue)
    }

    var watchAccent: Color {
        let rgb = watchAccentRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func watchLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

extension View {
    func watchCanvas(_ store: ChatStore) -> some View {
        let scheme = store.appearance.colorScheme ?? .dark
        let base: Color = scheme == .light ? .white : .black
        return self
            .foregroundStyle(scheme == .light ? Color.black : Color.white)
            .background {
                base.overlay(store.watchAccent.opacity(scheme == .light ? 0.045 : 0.025))
                    .ignoresSafeArea()
            }
            .environment(\.colorScheme, scheme)
    }
}

struct WatchHistory: View {
    @EnvironmentObject private var store: ChatStore
    @State private var pendingDelete: Conversation?
    @State private var managing = false
    let didSelect: () -> Void

    var body: some View {
        List {
            Button {
                store.newChat()
                didSelect()
            } label: {
                Label("新建对话", systemImage: "square.and.pencil")
                    .foregroundStyle(store.watchAccent)
            }
            if store.conversations.isEmpty {
                Text("对话会保存在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.conversations) { conversation in
                        Button {
                            if managing {
                                pendingDelete = conversation
                            } else {
                                store.open(conversation)
                                didSelect()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title).font(.headline).lineLimit(2)
                                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if managing {
                                    Image(systemName: "trash").foregroundStyle(.red)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = conversation
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: "删除") { pendingDelete = conversation }
                    }
                } header: {
                    Button(managing ? "完成" : "管理对话") { managing.toggle() }
                        .font(.footnote)
                        .foregroundStyle(store.watchAccent)
                        .buttonStyle(.plain)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .watchCanvas(store)
        .navigationTitle("历史对话")
        .confirmationDialog("删除这段对话？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingDelete) { conversation in
            Button("删除", role: .destructive) { store.delete(conversation) }
            Button("取消", role: .cancel) {}
        } message: { conversation in
            Text(conversation.title)
        }
    }
}

struct WatchSettings: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        List {
            Section("对话") {
                NavigationLink {
                    WatchModels()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("模型")
                        Text(store.selectedModel?.name ?? "尚未配置")
                            .font(.footnote)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Markdown 排版", isOn: $store.markdownEnabled)
            }
            Section("外观") {
                NavigationLink {
                    List {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Button { store.appearance = mode } label: {
                                HStack {
                                    Text(mode.label)
                                    Spacer()
                                    if store.appearance == mode {
                                        Image(systemName: "checkmark").foregroundStyle(store.watchAccent)
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .watchCanvas(store)
                    .navigationTitle("明暗模式")
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("明暗模式")
                        Text(store.appearance.label).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    WatchTintPicker()
                } label: {
                    HStack {
                        Text("主题色")
                        Spacer(minLength: 4)
                        Circle().fill(store.tint.color).frame(width: 14, height: 14)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .watchCanvas(store)
        .navigationTitle("设置")
    }
}

struct WatchModels: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if store.providers.allSatisfy({ $0.models.isEmpty }) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title2)
                        .foregroundStyle(store.watchAccent)
                    Text("从 iPhone 添加模型").font(.headline)
                    Text("打开 iPhone 上的 Arc Watch，在「服务商」中添加服务商和模型。配置会自动同步到手表。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.providers.filter { !$0.models.isEmpty }) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { model in
                            Button {
                                store.select(providerID: provider.id, modelID: model.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 5) {
                                    Text(model.name).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if store.selectedProviderID == provider.id && store.selectedModelID == model.id {
                                        Image(systemName: "checkmark").foregroundStyle(store.watchAccent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .watchCanvas(store)
        .navigationTitle("选择模型")
    }
}

private struct WatchTintPicker: View {
    @EnvironmentObject private var store: ChatStore
    // Keep the hue control aligned with a preset or a custom color synced from the phone.
    private var hue: Double {
        let rgb = store.tint.hex
        let r = Double(rgb >> 16 & 255), g = Double(rgb >> 8 & 255), b = Double(rgb & 255)
        let high = max(r, g, b)
        let range = high - min(r, g, b)
        guard range > 0 else { return 0 }
        let sector: Double
        if high == r { sector = (g - b) / range }
        else if high == g { sector = (b - r) / range + 2 }
        else { sector = (r - g) / range + 4 }
        return (sector + 6).truncatingRemainder(dividingBy: 6) / 6
    }

    var body: some View {
        List {
            Section("自定义色相") {
                Slider(value: Binding(
                    get: { min((hue * 36).rounded(), 35) },
                    set: { store.tint = AccentTint(hue: $0 / 36) }
                ), in: 0...35, step: 1) {
                    Text("色相")
                }
                .accessibilityValue("\(Int(hue * 360)) 度")
                .tint(Color(hue: hue, saturation: 0.66, brightness: 0.9))
            }
            Section("预设") {
                ForEach(AccentTint.allCases, id: \.self) { tint in
                    Button {
                        store.tint = tint
                    } label: {
                        HStack {
                            Circle().fill(tint.color).frame(width: 15, height: 15)
                            Text(tint.label)
                            Spacer(minLength: 0)
                            if tint == store.tint {
                                Image(systemName: "checkmark").foregroundStyle(store.watchAccent)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .watchCanvas(store)
        .navigationTitle("主题色")
    }
}
