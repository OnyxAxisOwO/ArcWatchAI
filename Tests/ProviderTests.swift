import Foundation
import XCTest
@testable import ArcWatchCore

final class ProviderTests: XCTestCase {
    private typealias JSON = [String: Any]
    private let key = "fixture"
    private let model = ChatModel(id: "gpt-6-sol", name: "GPT 6 Sol")

    private func provider(_ kind: ProviderKind, _ base: String) -> ProviderConfig {
        ProviderConfig(id: UUID(), name: "Test", kind: kind, baseURL: base, models: [])
    }

    private func prompt() -> [ChatMessage] {
        [ChatMessage(id: UUID(), role: .user, text: "北京今天的天气？")]
    }

    func testOpenAISearchUsesResponsesAndPlacesUnicodeCitationsInline() async throws {
        let fixture = StubSession { request, body in
            XCTAssertEqual(request.url?.path, "/gateway/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(body["model"] as? String, "gpt-6-sol")
            XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "none"])
            XCTAssertEqual(body["tools"] as? [[String: String]], [["type": "web_search"]])
            XCTAssertEqual(body["tool_choice"] as? String, "required")
            XCTAssertEqual((body["input"] as? [[String: String]])?.last?["role"], "user")
            return (200, ["output": [["type": "message", "content": [[
                "type": "output_text", "text": "☀️晴。微风。",
                "annotations": [["type": "url_citation", "url": "https://example.org/a(b)", "end_index": 4]]
            ]]]]])
        }
        let reply = try await AIClient.reply(provider: provider(.openAI, fixture.base + "/gateway/v1"), key: key,
                                             model: model, messages: prompt(), search: true, thinking: false, session: fixture.session)
        XCTAssertEqual(reply, "☀️晴。 [example.org](https://example.org/a%28b%29)微风。")
    }

    func testDeepSeekFlashAndProUseDocumentedSearchTools() async throws {
        for (id, tool) in [("deepseek-flash", "deepseek_web_search"), ("deepseek-v4-pro", "web_search")] {
            let fixture = StubSession { request, body in
                XCTAssertEqual(request.url?.path, "/responses")
                XCTAssertEqual(body["tools"] as? [[String: String]], [["type": tool]])
                XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "high"])
                return (200, ["output": [["type": "message", "content": [["type": "output_text", "text": "找到结果。"]]]]])
            }
            let answer = try await AIClient.reply(provider: provider(.deepSeek, fixture.base), key: key,
                                                  model: .init(id: id, name: id), messages: prompt(),
                                                  search: true, thinking: true, session: fixture.session)
            XCTAssertEqual(answer, "找到结果。")
        }
    }

    func testPlainDeepSeekChatHonorsThinkingSwitch() async throws {
        let fixture = StubSession { request, body in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
            XCTAssertNil(body["tools"])
            return (200, ["choices": [["message": ["role": "assistant", "content": "你好", "reasoning_content": "hidden"]]]])
        }
        let reply = try await AIClient.reply(provider: provider(.deepSeek, fixture.base + "/v1"), key: key,
                                             model: .init(id: "deepseek-flash", name: "Flash"), messages: prompt(),
                                             search: false, thinking: false, session: fixture.session)
        XCTAssertEqual(reply, "你好")
    }

    func testOpenAICompatibleGatewayFallsBackOnlyForMissingEndpoint() async throws {
        let fixture = StubSession { request, body in
            if request.url?.path == "/custom/v1/responses" { return (404, ["detail": "Not Found"]) }
            XCTAssertEqual(request.url?.path, "/custom/v1/chat/completions")
            XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
            return (200, ["choices": [["message": ["role": "assistant", "content": "收到。"]]]])
        }
        let answer = try await AIClient.reply(provider: provider(.openAI, fixture.base + "/custom/v1/chat/completions"), key: key,
                                              model: model, messages: prompt(), search: false, thinking: true, session: fixture.session)
        XCTAssertEqual(answer, "收到。")
        XCTAssertEqual(fixture.count, 2)

        let noModel = StubSession { _, _ in (404, ["error": ["code": "model_not_found", "message": "Unknown model"]]) }
        do {
            _ = try await AIClient.reply(provider: provider(.openAI, noModel.base), key: key, model: model, messages: prompt(),
                                         search: false, thinking: true, session: noModel.session)
            XCTFail("Expected provider error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unknown model"))
        }
        XCTAssertEqual(noModel.count, 1)
    }

    func testUnsupportedReasoningFieldCanBeOmittedButUnsupportedOffValueIsReported() async throws {
        let oldGateway = StubSession { _, body in
            if body["reasoning"] != nil { return (400, ["error": ["message": "Unknown parameter: reasoning"]]) }
            return (200, ["output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]]])
        }
        let answer = try await AIClient.reply(provider: provider(.openAI, oldGateway.base), key: key, model: model,
                                              messages: prompt(), search: false, thinking: false, session: oldGateway.session)
        XCTAssertEqual(answer, "ok")
        XCTAssertEqual(oldGateway.count, 2)

        let alwaysOn = StubSession { _, _ in (400, ["error": ["message": "Unsupported value: reasoning.effort 'none'"]]) }
        do {
            _ = try await AIClient.reply(provider: provider(.openAI, alwaysOn.base), key: key, model: model,
                                         messages: prompt(), search: false, thinking: false, session: alwaysOn.session)
            XCTFail("Expected an unsupported mode")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("none"))
        }
        XCTAssertEqual(alwaysOn.count, 1)
    }

    func testClaudeDiscoveryKeepsDisplayNamesAndPaginates() async throws {
        let fixture = StubSession { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            if request.url?.query == nil {
                return (200, ["data": [["id": "a", "display_name": "Alpha"]], "has_more": true, "last_id": "a"])
            }
            XCTAssertEqual(request.url?.query, "after_id=a")
            return (200, ["data": [["id": "b", "display_name": "Beta"], ["id": "a", "display_name": "Alpha"]], "has_more": false])
        }
        let models = try await AIClient.discover(provider: provider(.anthropic, fixture.base), key: key, session: fixture.session)
        XCTAssertEqual(models.map(\.id), ["a", "b"])
        XCTAssertEqual(models.map(\.name), ["Alpha", "Beta"])
    }

    func testClaudeResumesPausedSearchWithOriginalContentBlocks() async throws {
        let block: JSON = ["type": "server_tool_use", "name": "web_search", "id": "srv_123", "input": ["query": "北京"]]
        let fixture = StubSession { request, body in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(body["thinking"] as? [String: String], ["type": "adaptive"])
            XCTAssertEqual((body["tools"] as? [JSON])?.first?["name"] as? String, "web_search")
            let messages = try XCTUnwrap(body["messages"] as? [JSON])
            if messages.count == 1 { return (200, ["content": [block], "stop_reason": "pause_turn"]) }
            XCTAssertEqual(((messages.last?["content"] as? [JSON])?.first)?["id"] as? String, "srv_123")
            return (200, ["content": [["type": "text", "text": "北京晴朗。", "citations": [["url": "https://example.org/weather"]]]],
                          "stop_reason": "end_turn"])
        }
        let answer = try await AIClient.reply(provider: provider(.anthropic, fixture.base), key: key,
                                              model: .init(id: "claude-sonnet-4-6", name: "Sonnet"), messages: prompt(),
                                              search: true, thinking: true, session: fixture.session)
        XCTAssertEqual(answer, "北京晴朗。 [example.org](https://example.org/weather)")
        XCTAssertEqual(fixture.count, 2)
    }
}

/// Each fixture has a unique hostname so test requests can run concurrently.
private final class StubSession {
    typealias Handler = (URLRequest, [String: Any]) throws -> (Int, [String: Any])
    let host = UUID().uuidString.lowercased() + ".test"
    var base: String { "https://" + host }
    let session: URLSession
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }

    init(_ handler: @escaping Handler) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        StubProtocol.install(for: host) { [weak self] request, body in
            self?.increment()
            return try handler(request, body)
        }
    }

    private func increment() { lock.withLock { calls += 1 } }

    deinit {
        session.invalidateAndCancel()
        StubProtocol.install(for: host, handler: nil)
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers = [String: StubSession.Handler]()

    static func install(for host: String, handler: StubSession.Handler?) {
        lock.withLock { handlers[host] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let handler = try XCTUnwrap(Self.lock.withLock { Self.handlers[url.host ?? ""] })
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var read = stream.read(&bytes, maxLength: bytes.count)
                while read > 0 {
                    data.append(contentsOf: bytes.prefix(read))
                    read = stream.read(&bytes, maxLength: bytes.count)
                }
            }
            let body = data.isEmpty ? [:] : try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let (status, object) = try handler(request, body)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
