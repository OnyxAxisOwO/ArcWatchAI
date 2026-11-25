import SwiftUI

struct PhoneProviders: View {
    @EnvironmentObject private var store: ChatStore
    @State private var editor: ProviderSheet?
    @State private var removal: ProviderConfig?

    var body: some View {
        Group {
            if store.providers.isEmpty {
                ContentUnavailableView {
                    Label("连接服务商", systemImage: "square.stack.3d.up")
                } description: {
                    Text("添加 API 地址、密钥和模型。配置会同步到配对的 Apple Watch。")
                } actions: {
                    Button("添加服务商") { editor = .new }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            } else {
                List {
                    Section {
                        ForEach(store.providers) { provider in
                            Button {
                                editor = .edit(provider)
                            } label: {
                                HStack(spacing: 13) {
                                    ProviderGlyph(kind: provider.kind)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(provider.name).font(.headline).foregroundStyle(.primary)
                                        Text("\(provider.kind.label) · \(provider.models.count) 个模型")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .swipeActions {
                                Button(role: .destructive) { removal = provider } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Label("服务商与模型会同步到配对的 Apple Watch。", systemImage: "applewatch")
                    }
                }
            }
        }
        .navigationTitle("服务商")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor = .new } label: { Label("添加服务商", systemImage: "plus") }
            }
        }
        .sheet(item: $editor) { sheet in
            ProviderEditor(existing: sheet.provider)
        }
        .confirmationDialog("删除服务商？", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible, presenting: removal) { provider in
            Button("删除「\(provider.name)」", role: .destructive) { store.delete(provider: provider) }
            Button("取消", role: .cancel) {}
        }
    }
}

private enum ProviderSheet: Identifiable {
    case new, edit(ProviderConfig)
    var provider: ProviderConfig? {
        if case let .edit(value) = self { return value }
        return nil
    }
    var id: String { provider?.id.uuidString ?? "new" }
}

private struct ProviderGlyph: View {
    let kind: ProviderKind
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        Group {
            switch kind {
            case .openAI: Image(systemName: "circle.hexagongrid")
            case .anthropic: Image(systemName: "asterisk")
            case .deepSeek: Image(systemName: "water.waves")
            }
        }
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(store.tint.color)
        .frame(width: 44, height: 44)
        .background(store.tint.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityHidden(true)
    }
}

private enum ModelSheet: Identifiable {
    case new, edit(ChatModel), discovered([ChatModel])
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let model): "edit-\(model.id)"
        case .discovered: "discovered"
        }
    }
}

struct ProviderEditor: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    let existing: ProviderConfig?
    @State private var id: UUID
    @State private var name: String
    @State private var kind: ProviderKind
    @State private var address: String
    @State private var key = ""
    @State private var didLoadKey = false
    @State private var revealKey = false
    @State private var models: [ChatModel]
    @State private var modelSheet: ModelSheet?
    @State private var errorText: String?
    @State private var discovery: Task<Void, Never>?

    init(existing: ProviderConfig?) {
        self.existing = existing
        let initialKind = existing?.kind ?? .openAI
        _id = State(initialValue: existing?.id ?? UUID())
        _name = State(initialValue: existing?.name ?? initialKind.label)
        _kind = State(initialValue: initialKind)
        _address = State(initialValue: existing?.baseURL ?? initialKind.defaultBaseURL)
        _models = State(initialValue: existing?.models ?? [])
    }

    private var config: ProviderConfig {
        ProviderConfig(id: id, name: name.cleaned, kind: kind, baseURL: address.cleaned, models: models)
    }

    private var canConnect: Bool {
        guard let url = URL(string: address.cleaned), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    Picker("协议", selection: $kind) {
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    LabeledContent("名称") {
                        TextField("服务商名称", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API 地址").font(.subheadline)
                        TextField(kind.defaultBaseURL, text: $address)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 2)
                    HStack {
                        Group {
                            if revealKey {
                                TextField("API Key", text: $key)
                            } else {
                                SecureField("API Key", text: $key)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        Button {
                            revealKey.toggle()
                        } label: {
                            Label(revealKey ? "隐藏密钥" : "显示密钥", systemImage: revealKey ? "eye.slash" : "eye")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .disabled(discovery != nil)

                Section {
                    Button {
                        discoverModels()
                    } label: {
                        HStack {
                            Label(discovery == nil ? "自动检测模型" : "正在检测模型…", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if discovery != nil { ProgressView() }
                        }
                    }
                    .disabled(!canConnect || discovery != nil)
                    Button {
                        modelSheet = .new
                    } label: {
                        Label("手动添加模型", systemImage: "plus")
                    }
                    .disabled(discovery != nil)
                    ForEach(models) { model in
                        Button { modelSheet = .edit(model) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name).foregroundStyle(.primary)
                                    Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .swipeActions {
                            Button(role: .destructive) { models.removeAll { $0.id == model.id } } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("模型（\(models.count)）")
                } footer: {
                    Text("模型编号用于 API 请求，显示名称可自行修改。")
                }
            }
            .navigationTitle(existing == nil ? "添加服务商" : "编辑服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        discovery?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try store.save(provider: config, key: key.cleaned)
                            dismiss()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                    .disabled(name.cleaned.isEmpty || !canConnect || discovery != nil)
                }
            }
            .onAppear {
                if !didLoadKey {
                    if existing != nil { key = store.key(for: id) }
                    didLoadKey = true
                }
            }
            .onDisappear { discovery?.cancel() }
            .onChange(of: kind) { previous, new in
                if name.cleaned.isEmpty || name == previous.label { name = new.label }
                if address.cleaned.isEmpty || address == previous.defaultBaseURL { address = new.defaultBaseURL }
            }
            .sheet(item: $modelSheet) { sheet in
                switch sheet {
                case .new:
                    ModelEditor(existing: nil, models: $models)
                case .edit(let model):
                    ModelEditor(existing: model, models: $models)
                case .discovered(let results):
                    ModelDiscovery(results: results, models: $models)
                }
            }
            .alert("服务商配置", isPresented: Binding(
                get: { errorText != nil }, set: { if !$0 { errorText = nil } }
            )) {
                Button("好") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func discoverModels() {
        guard discovery == nil else { return }
        discovery = Task { @MainActor in
            defer { discovery = nil }
            do {
                let result = try await AIClient.discover(provider: config, key: key.cleaned)
                try Task.checkCancellation()
                if result.isEmpty {
                    errorText = "服务商未返回模型。你可以使用模型编号手动添加。"
                } else {
                    var seen = Set<String>()
                    modelSheet = .discovered(result.filter { seen.insert($0.id).inserted })
                }
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }
}

private struct ModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: ChatModel?
    @Binding var models: [ChatModel]
    @State private var identifier: String
    @State private var displayName: String

    init(existing: ChatModel?, models: Binding<[ChatModel]>) {
        self.existing = existing
        _models = models
        _identifier = State(initialValue: existing?.id ?? "")
        _displayName = State(initialValue: existing?.name ?? "")
    }

    private var duplicate: Bool {
        models.contains { $0.id == identifier.cleaned && $0.id != existing?.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型编号").font(.subheadline)
                        TextField("例如 gpt-6-sol", text: $identifier)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.vertical, 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("显示名称").font(.subheadline)
                        TextField(identifier.cleaned.isEmpty ? "例如 GPT 6 Sol" : identifier.cleaned, text: $displayName)
                    }
                    .padding(.vertical, 3)
                } footer: {
                    if duplicate { Text("这个模型编号已经存在。").foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "添加模型" : "编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let id = identifier.cleaned
                        let model = ChatModel(id: id, name: displayName.cleaned.isEmpty ? id : displayName.cleaned)
                        if let index = models.firstIndex(where: { $0.id == existing?.id }) {
                            models[index] = model
                        } else {
                            models.append(model)
                        }
                        dismiss()
                    }
                    .disabled(identifier.cleaned.isEmpty || duplicate)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ModelDiscovery: View {
    @Environment(\.dismiss) private var dismiss
    let results: [ChatModel]
    @Binding var models: [ChatModel]
    @State private var selected: Set<String> = []
    @State private var search = ""

    private var visible: [ChatModel] {
        results.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let existing = Set(models.map(\.id))
        let available = Set(visible.map(\.id)).subtracting(existing)
        NavigationStack {
            List {
                if !available.isEmpty {
                    Button(available.isSubset(of: selected) ? "取消全选" : "全选当前结果") {
                        if available.isSubset(of: selected) { selected.subtract(available) }
                        else { selected.formUnion(available) }
                    }
                }
                ForEach(visible) { model in
                    let added = existing.contains(model.id)
                    let checked = selected.contains(model.id)
                    Button {
                        if checked { selected.remove(model.id) } else { selected.insert(model.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name).foregroundStyle(.primary)
                                if model.id != model.name {
                                    Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if added {
                                Text("已添加").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(added)
                    .accessibilityAddTraits(checked || added ? .isSelected : [])
                }
            }
            .searchable(text: $search, prompt: "查找模型")
            .navigationTitle("检测到 \(results.count) 个模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加（\(selected.count)）") {
                        models.append(contentsOf: results.filter { selected.contains($0.id) && !existing.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

private extension String {
    var cleaned: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
