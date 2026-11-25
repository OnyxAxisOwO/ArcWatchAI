import Foundation
import XCTest
@testable import ArcWatchCore

final class HistoryTests: XCTestCase {
    func testOfflineRepliesStayWithTheirQuestionOnEitherDevice() {
        let chat = UUID()
        let first = ChatMessage(role: .user, text: "一", createdAt: Date(timeIntervalSince1970: 1))
        let second = ChatMessage(role: .user, text: "二", createdAt: Date(timeIntervalSince1970: 2))
        let answer = ChatMessage(role: .assistant, text: "答一", createdAt: Date(timeIntervalSince1970: 3), replyTo: first.id)
        var phone = History(chats: [chat: Conversation(id: chat, messages: [first, answer])])
        var watch = History(chats: [chat: Conversation(id: chat, messages: [first, second])])
        phone.merge(watch); watch.merge(phone); phone.merge(watch)
        XCTAssertEqual(phone, watch)
        XCTAssertEqual(phone.chats[chat]?.messages.map(\.text), ["一", "答一", "二"])
        var deletion = History(deleted: [chat]); deletion.merge(phone); watch.merge(deletion)
        XCTAssertEqual(deletion, watch)
        XCTAssertNil(watch.chats[chat])
    }
}
