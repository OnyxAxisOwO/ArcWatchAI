import Foundation
import Combine

private struct LocalState: Codable {
    var providers: [ProviderConfig] = []
    var catalogRevision: Double = 0
    var settings: [String: SettingValue] = [:]
    var history = History()
    var writer = UUID().uuidString
}

private struct PairSnapshot: Codable {
    struct Catalog: Codable {
        let revision: Double
        let providers: [ProviderConfig]
        let keys: [UUID: String]
    }
    let catalog: Catalog?
    let settings: [String: SettingValue]
    let history: History
}

@MainActor final class ChatStore: ObservableObject {
    @Published private(set) var providers: [ProviderConfig] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var selectedProviderID: UUID?
    @Published private(set) var selectedModelID = ""
    @Published var searchEnabled = false { didSet { record("search", String(searchEnabled)) } }
    @Published var thinkingEnabled = false { didSet { record("thinking", String(thinkingEnabled)) } }
    @Published var markdownEnabled = true { didSet { record("markdown", String(markdownEnabled)) } }
    @Published var appearance = AppearanceMode.system { didSet { record("appearance", appearance.rawValue) } }
    @Published var tint = AccentTint.jade { didSet { record("tint", String(tint.hex)) } }
    @Published private(set) var isSending = false
    @Published var errorMessage: String?
    var selectedProvider: ProviderConfig? { providers.first { $0.id == selectedProviderID } }
    var selectedModel: ChatModel? { selectedProvider?.models.first { $0.id == selectedModelID } }

    private var state = LocalState()
    private var currentID: UUID?
    private var applying = false
    private var request: Task<String, Error>?
    private var requestID: UUID?
    private var syncTask: Task<Void, Never>?
    private let link = PairLink()
    private let file = URL.applicationSupportDirectory.appending(path: "arcwatch.json")

    init() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file))
            }
        } catch { errorMessage = "读取本机数据失败：" + error.localizedDescription }
        refresh()
        link.receive = { [weak self] in self?.receive($0) }
        link.ready = { [weak self] in self?.scheduleSync() }
        link.activate()
    }

    func key(for id: UUID) -> String { (try? CredentialStore.read(id)) ?? "" }

    func save(provider: ProviderConfig, key: String) throws {
        try CredentialStore.write(key, id: provider.id)
        if let index = state.providers.firstIndex(where: { $0.id == provider.id }) {
            state.providers[index] = provider
        } else { state.providers.append(provider) }
        changedCatalog()
    }

    func delete(provider: ProviderConfig) {
        do { try CredentialStore.delete(provider.id) } catch { errorMessage = error.localizedDescription; return }
        state.providers.removeAll { $0.id == provider.id }
        changedCatalog()
    }

    private func changedCatalog() {
        state.catalogRevision = max(Date.now.timeIntervalSince1970, state.catalogRevision.nextUp)
        providers = state.providers
        resolveSelection()
        if let id = selectedProviderID { select(providerID: id, modelID: selectedModelID) }
        commit()
    }

    func select(providerID: UUID, modelID: String) {
        guard providers.contains(where: { $0.id == providerID && $0.models.contains(where: { $0.id == modelID }) }) else { return }
        selectedProviderID = providerID
        selectedModelID = modelID
        record("selection", providerID.uuidString + "/" + modelID)
    }

    private func resolveSelection() {
        let parts = state.settings["selection"]?.value.split(separator: "/", maxSplits: 1)
        if let parts, parts.count == 2, let id = UUID(uuidString: String(parts[0])),
           providers.contains(where: { $0.id == id && $0.models.contains(where: { $0.id == parts[1] }) }) {
            selectedProviderID = id; selectedModelID = String(parts[1])
        } else {
            let first = providers.first { !$0.models.isEmpty }
            selectedProviderID = first?.id; selectedModelID = first?.models.first?.id ?? ""
        }
    }

    func newChat() { cancel(); currentID = nil; messages = []; errorMessage = nil }
    func open(_ conversation: Conversation) {
        cancel(); currentID = conversation.id; messages = state.history.chats[conversation.id]?.messages ?? []; errorMessage = nil
    }
    func delete(_ conversation: Conversation) {
        if currentID == conversation.id { newChat() }
        state.history.deleted.insert(conversation.id)
        state.history.chats[conversation.id] = nil
        refreshHistory(); commit()
    }

    func send(_ text: String, onAccepted: () -> Void = {}) async {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isSending else { return }
        guard let provider = selectedProvider, let model = selectedModel else {
            errorMessage = "请先在 iPhone 添加服务商并选择模型。"; return
        }
        let credential: String
        do {
            guard let key = try CredentialStore.read(provider.id) else {
                errorMessage = "尚未收到此服务商的密钥，请在 iPhone 确认配置。"; return
            }
            credential = key
        } catch { errorMessage = error.localizedDescription; return }
        let id = currentID ?? UUID(), token = UUID(), question = ChatMessage(role: .user, text: input)
        currentID = id; requestID = token; isSending = true; errorMessage = nil
        append(question, to: id)
        onAccepted()
        let history = messages, search = searchEnabled, thinking = thinkingEnabled
        let task = Task {
            try await AIClient.reply(provider: provider, key: credential, model: model, messages: history, search: search, thinking: thinking)
        }
        request = task
        defer { if requestID == token { requestID = nil; request = nil; isSending = false } }
        do {
            let reply = try await task.value
            guard requestID == token, !task.isCancelled, !state.history.deleted.contains(id) else { return }
            append(ChatMessage(role: .assistant, text: reply, replyTo: question.id), to: id)
        } catch { if requestID == token && !task.isCancelled { errorMessage = error.localizedDescription } }
    }

    func cancel() { request?.cancel(); request = nil; requestID = nil; isSending = false }

    private func append(_ message: ChatMessage, to id: UUID) {
        let added = Conversation(id: id, messages: [message])
        if state.history.chats[id] == nil { state.history.chats[id] = added } else { state.history.chats[id]?.merge(added) }
        refreshHistory(); commit()
    }

    private func record(_ field: String, _ value: String) {
        guard !applying, state.settings[field]?.value != value else { return }
        state.settings[field] = .init(value: value, revision: (state.settings[field]?.revision ?? 0) + 1, writer: state.writer)
        commit()
    }

    private func refresh() {
        applying = true
        defer { applying = false }
        providers = state.providers
        let values = state.settings.mapValues(\.value)
        searchEnabled = values["search"].flatMap(Bool.init) ?? false
        thinkingEnabled = values["thinking"].flatMap(Bool.init) ?? false
        markdownEnabled = values["markdown"].flatMap(Bool.init) ?? true
        appearance = values["appearance"].flatMap(AppearanceMode.init(rawValue:)) ?? .system
        tint = values["tint"].flatMap(Int.init).map(AccentTint.init(hex:)) ?? .jade
        resolveSelection(); refreshHistory()
    }

    private func refreshHistory() {
        if let id = currentID, state.history.deleted.contains(id) { newChat() }
        conversations = state.history.chats.values.sorted { $0.updatedAt > $1.updatedAt }
        messages = currentID.flatMap { state.history.chats[$0]?.messages } ?? []
    }

    private func commit() { persist(); scheduleSync() }
    private func persist() {
        do { try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { errorMessage = "保存本机数据失败：" + error.localizedDescription }
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            do {
                var catalog: PairSnapshot.Catalog?
                #if os(iOS)
                var keys: [UUID: String] = [:]
                for provider in state.providers { keys[provider.id] = try CredentialStore.read(provider.id) }
                if keys.count == state.providers.count {
                    catalog = .init(revision: state.catalogRevision, providers: state.providers, keys: keys)
                }
                #endif
                let snapshot = PairSnapshot(catalog: catalog, settings: state.settings, history: state.history)
                let encoder = PropertyListEncoder()
                try link.send(encoder.encode(snapshot))
            } catch { errorMessage = "配对同步失败：" + error.localizedDescription }
        }
    }

    private func receive(_ data: Data) {
        do {
            let snapshot = try PropertyListDecoder().decode(PairSnapshot.self, from: data)
            var changed = false
            #if os(watchOS)
            if let catalog = snapshot.catalog, catalog.revision >= state.catalogRevision {
                // A restored watch can have its catalog but lack this-device-only Keychain items.
                for (id, key) in catalog.keys where try CredentialStore.read(id) != key {
                    try CredentialStore.write(key, id: id)
                }
                if catalog.revision > state.catalogRevision {
                    for old in state.providers where !catalog.providers.contains(where: { $0.id == old.id }) {
                        try CredentialStore.delete(old.id)
                    }
                    state.providers = catalog.providers; state.catalogRevision = catalog.revision; changed = true
                }
            }
            #endif
            for (field, incoming) in snapshot.settings where state.settings[field]?.precedes(incoming) ?? true {
                state.settings[field] = incoming; changed = true
            }
            let previous = state.history
            state.history.merge(snapshot.history)
            if changed || previous != state.history { refresh(); persist() }
        } catch { errorMessage = "读取配对设备数据失败：" + error.localizedDescription }
    }
}
