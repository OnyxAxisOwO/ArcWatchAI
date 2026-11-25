import Foundation

enum ProviderKind: String, CaseIterable, Codable, Identifiable {
    case openAI, anthropic, deepSeek
    var id: Self { self }
    var label: String {
        switch self { case .openAI: "OpenAI"; case .anthropic: "Anthropic"; case .deepSeek: "DeepSeek" }
    }
    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        }
    }
}

struct ChatModel: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

struct ProviderConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var models: [ChatModel]
}

enum MessageRole: String, Codable { case user, assistant }

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: MessageRole
    var text: String
    var createdAt = Date()
    var replyTo: UUID?
}

struct Conversation: Identifiable, Codable, Equatable {
    var id: UUID
    var messages: [ChatMessage]
    var title: String { String((messages.first?.text ?? "新对话").split(whereSeparator: \.isNewline).first.map { $0.prefix(48) } ?? "新对话") }
    var updatedAt: Date { messages.map(\.createdAt).max() ?? .distantPast }

    // Two devices can continue the same chat while offline. Keep each reply with its question.
    mutating func merge(_ other: Conversation) {
        var ids = Set(messages.map(\.id))
        messages.append(contentsOf: other.messages.filter { ids.insert($0.id).inserted })
        let ordered = messages.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        let questions = Set(ordered.filter { $0.role == .user }.map(\.id))
        let replies = Dictionary(grouping: ordered.filter { $0.replyTo.map(questions.contains) == true }, by: \.replyTo)
        messages = ordered.filter { $0.replyTo.map(questions.contains) != true }.flatMap { [$0] + (replies[$0.id] ?? []) }
    }
}

struct History: Codable, Equatable {
    var chats: [UUID: Conversation] = [:]
    var deleted: Set<UUID> = []

    mutating func merge(_ other: Self) {
        deleted.formUnion(other.deleted)
        for id in deleted { chats.removeValue(forKey: id) }
        for (id, incoming) in other.chats where !deleted.contains(id) {
            if chats[id] == nil { chats[id] = incoming } else { chats[id]?.merge(incoming) }
        }
    }
}

// A separate logical revision per preference lets unrelated offline edits coexist.
struct SettingValue: Codable, Equatable {
    var value: String
    var revision: Int
    var writer: String
    func precedes(_ next: Self) -> Bool { (revision, writer) < (next.revision, next.writer) }
}
