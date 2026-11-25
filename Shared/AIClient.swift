import Foundation

/// A base URL is the API root (including any custom path prefix).
/// Chat history stays on the client and is sent explicitly with each request.
enum AIClient {
    typealias JSON = [String: Any]

    struct APIError: LocalizedError {
        let message: String
        var status: Int?
        var code: String?
        var errorDescription: String? { message }

        var isMissingEndpoint: Bool {
            let lower = message.lowercased()
            if code == "model_not_found" || lower.contains("model does not exist") || lower.contains("model not found") { return false }
            if let status, [404, 405, 501].contains(status) { return true }
            return status == 400 && ["unsupported endpoint", "unknown endpoint", "unknown request url"].contains(where: lower.contains)
        }

        init(_ message: String, status: Int? = nil, code: String? = nil) {
            self.message = message
            self.status = status
            self.code = code
        }
    }

    static func discover(provider: ProviderConfig, key: String, session: URLSession = .shared) async throws -> [ChatModel] {
        var found = [ChatModel]()
        var knownIDs = Set<String>()
        var cursors = Set<String>()
        var after: String?
        repeat {
            var request = try makeRequest(provider, key: key, path: "models")
            if let after, let url = request.url {
                request.url = url.appending(queryItems: [URLQueryItem(name: "after_id", value: after)])
            }
            let page = try await perform(request, session: session)
            guard let records = page["data"] as? [JSON] else {
                throw APIError("服务商返回的模型列表格式无效。请检查 Base URL 和服务商类型。")
            }
            for record in records {
                guard let id = record["id"] as? String, !id.isEmpty, knownIDs.insert(id).inserted else { continue }
                let displayName = (record["display_name"] ?? record["name"]) as? String
                found.append(ChatModel(id: id, name: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? id))
            }
            after = nil
            if provider.kind == .anthropic, page["has_more"] as? Bool == true {
                guard let cursor = page["last_id"] as? String, !cursor.isEmpty, cursors.insert(cursor).inserted else {
                    throw APIError("服务商返回了无效的模型列表分页信息。")
                }
                after = cursor
            }
        } while after != nil
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func reply(provider: ProviderConfig, key: String, model: ChatModel, messages: [ChatMessage],
                      search: Bool, thinking: Bool, session: URLSession = .shared) async throws -> String {
        let history = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        if provider.kind == .anthropic {
            return try await anthropicReply(provider, key: key, model: model.id, history: history,
                                            search: search, thinking: thinking, session: session)
        }
        if provider.kind == .deepSeek && !search {
            return try await chatCompletion(provider, key: key, model: model.id, history: history,
                                            thinking: thinking, session: session)
        }

        var body: JSON = ["model": model.id, "input": history, "store": false]
        if provider.kind == .deepSeek {
            body["reasoning"] = ["effort": thinking ? "high" : "none"]
            let tool = model.id.lowercased().contains("v4-pro") ? "web_search" : "deepseek_web_search"
            body["tools"] = [["type": tool]]
        } else {
            if let effort = openAIEffort(model: model.id, thinking: thinking) {
                body["reasoning"] = ["effort": effort]
            }
            if search {
                body["tools"] = [["type": "web_search"]]
                body["tool_choice"] = "required"
            }
        }
        do {
            let response = try await post(provider, key: key, path: "responses", body: body, session: session)
            return try responseText(response)
        } catch let error as APIError {
            // Some compatible gateways only implement Chat Completions. Only retry
            // when the endpoint itself was unavailable and no hosted tool is needed.
            guard provider.kind == .openAI, !search, error.isMissingEndpoint else { throw error }
            return try await chatCompletion(provider, key: key, model: model.id, history: history,
                                            thinking: thinking, session: session)
        }
    }

    private static func openAIEffort(model: String, thinking: Bool) -> String? {
        if thinking { return "medium" }
        let id = model.split(separator: "/").last?.lowercased() ?? model.lowercased()
        // Models predating reasoning and GPT chat snapshots do not accept this field.
        if id.hasPrefix("gpt-4") || id.hasPrefix("gpt-3") || id.contains("-chat-") || id == "chatgpt-4o-latest" {
            return nil
        }
        return "none"
    }

    private static func chatCompletion(_ provider: ProviderConfig, key: String, model: String,
                                       history: [[String: String]], thinking: Bool, session: URLSession) async throws -> String {
        var body: JSON = ["model": model, "messages": history]
        if provider.kind == .deepSeek {
            body["thinking"] = ["type": thinking ? "enabled" : "disabled"]
        } else {
            body["reasoning_effort"] = openAIEffort(model: model, thinking: thinking)
        }
        let response = try await post(provider, key: key, path: "chat/completions", body: body, session: session)
        guard let choice = (response["choices"] as? [JSON])?.first,
              let message = choice["message"] as? JSON else { throw emptyReply }
        let answer = message["content"] as? String ?? message["refusal"] as? String ?? ""
        return try checkedAnswer(answer, stop: choice["finish_reason"] as? String)
    }

    private static func post(_ provider: ProviderConfig, key: String, path: String,
                             body: JSON, session: URLSession) async throws -> JSON {
        let request = try makeRequest(provider, key: key, path: path, body: body)
        do { return try await perform(request, session: session) }
        catch let error as APIError {
            // Older OpenAI-compatible gateways can reject the parameter itself.
            // Only omit an explicit "off" for a protocol with no reasoning field;
            // a model rejecting the value "none" must report that limitation.
            let field = path == "responses" ? "reasoning" : "reasoning_effort"
            let effort = (body[field] as? [String: String])?["effort"] ?? body[field] as? String
            let detail = error.message.lowercased()
            let unknownParameter = ["unknown parameter", "unrecognized request argument", "unsupported parameter",
                                    "unexpected keyword argument", "extra inputs are not permitted"].contains(where: detail.contains)
            guard provider.kind == .openAI, error.status == 400, effort == "none",
                  detail.contains("reasoning"), !detail.contains("none"), unknownParameter else { throw error }
            var compatibleBody = body
            compatibleBody.removeValue(forKey: field)
            return try await perform(makeRequest(provider, key: key, path: path, body: compatibleBody), session: session)
        }
    }

    private static func anthropicReply(_ provider: ProviderConfig, key: String, model: String,
                                       history: [[String: String]], search: Bool, thinking: Bool,
                                       session: URLSession) async throws -> String {
        var turns: [JSON] = history
        var body: JSON = ["model": model, "max_tokens": thinking ? 8192 : 4096]
        let id = model.lowercased()
        if thinking {
            // Claude 4.5 and earlier use manual budgets. Newer models use adaptive thinking.
            let legacy = id.range(of: #"claude-(?:3[-.]7|(?:opus|haiku|sonnet)-4(?:$|-(?:0|1|5)(?:-|$)|-20[0-9]{6}))"#,
                                  options: .regularExpression) != nil
            body["thinking"] = legacy ? ["type": "enabled", "budget_tokens": 2048] as JSON : ["type": "adaptive"]
        } else {
            body["thinking"] = ["type": id.contains("sonnet-5-5") ? "between_tools" : "disabled"]
        }
        if search {
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 5] as JSON]
        }
        var text = ""
        for _ in 0..<6 {
            body["messages"] = turns
            let request = try makeRequest(provider, key: key, path: "messages", body: body)
            let response = try await perform(request, session: session)
            guard let blocks = response["content"] as? [JSON] else { throw emptyReply }
            for block in blocks {
                if block["type"] as? String == "text", let part = block["text"] as? String {
                    text += citedText(part, annotations: block["citations"] as? [JSON] ?? [])
                }
                if block["type"] as? String == "web_search_tool_result",
                   let failure = block["content"] as? JSON, let code = failure["error_code"] as? String {
                    throw APIError("Claude 联网搜索失败（\(code)）。")
                }
            }
            let reason = response["stop_reason"] as? String
            if reason != "pause_turn" { return try checkedAnswer(text, stop: reason) }
            // The Messages API requires the exact server tool and thinking blocks to continue a paused turn.
            turns.append(["role": "assistant", "content": blocks])
        }
        throw APIError("Claude 联网检索尚未完成，请缩小问题范围后再试。")
    }

    private static func responseText(_ response: JSON) throws -> String {
        if let error = response["error"] as? JSON {
            throw APIError(error["message"] as? String ?? "服务商未能生成回复。")
        }
        let items = response["output"] as? [JSON] ?? []
        let texts: [String] = items.filter { $0["type"] as? String == "message" }.flatMap { item -> [String] in
            (item["content"] as? [JSON] ?? []).compactMap { block in
                switch block["type"] as? String {
                case "output_text":
                    guard let text = block["text"] as? String else { return nil }
                    return citedText(text, annotations: block["annotations"] as? [JSON] ?? [])
                case "refusal": return block["refusal"] as? String
                default: return nil
                }
            }
        }
        let answer = texts.joined(separator: "\n\n")
        let reason = (response["incomplete_details"] as? JSON)?["reason"] as? String
        return try checkedAnswer(answer, stop: reason)
    }

    private static var emptyReply: APIError { APIError("服务商未返回可显示的回复。请检查所选模型是否支持文本对话。") }

    private static func checkedAnswer(_ raw: String, stop: String?) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stop == "content_filter" && text.isEmpty { throw APIError("服务商的内容过滤器中止了本次回复。") }
        if ["length", "max_tokens", "max_output_tokens"].contains(stop) {
            guard !text.isEmpty else { throw APIError("模型已用完输出额度。请缩短问题或降低思考强度。") }
            return text + "\n\n（已达到服务商的单次输出上限。）"
        }
        guard !text.isEmpty else { throw emptyReply }
        return text
    }

    /// Responses offsets count Unicode scalars. Keep the cited sentence intact
    /// and insert a tappable Markdown source at its end, including on watchOS.
    private static func citedText(_ original: String, annotations: [JSON]) -> String {
        guard !annotations.isEmpty else { return original }
        let scalars = Array(original.unicodeScalars)
        var links = [Int: [String]]()
        var markerOffsets = IndexSet()
        for item in annotations {
            guard let raw = item["url"] as? String, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased()), let host = url.host, !host.isEmpty else { continue }
            let offset = item["end_index"] as? Int ?? scalars.count
            let at = (0...scalars.count).contains(offset) ? offset : scalars.count
            if let start = item["start_index"] as? Int, start >= 0, start < at {
                let span = String(String.UnicodeScalarView(scalars[start..<at]))
                if span.contains("](" + raw + ")") { continue }
                // Some compatible backends leave an internal citation marker in the
                // text. Replace only the marker, never the sentence it annotates.
                if span.hasPrefix("\u{E200}cite"), span.hasSuffix("\u{E201}") {
                    markerOffsets.insert(integersIn: start..<at)
                }
            }
            let destination = url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            let link = " [\(host)](\(destination))"
            if !(links[at]?.contains(link) ?? false) { links[at, default: []].append(link) }
        }
        var result = links[0]?.joined() ?? ""
        for (i, scalar) in scalars.enumerated() {
            if !markerOffsets.contains(i) { result.unicodeScalars.append(scalar) }
            if let references = links[i + 1] { result += references.joined() }
        }
        return result
    }

    private static func makeRequest(_ provider: ProviderConfig, key: String, path: String, body: JSON? = nil) throws -> URLRequest {
        let rawURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var base = URL(string: rawURL), ["https", "http"].contains(base.scheme?.lowercased()),
              let host = base.host, !host.isEmpty, base.fragment == nil else { throw APIError("请输入完整的 HTTP 或 HTTPS Base URL。") }
        // Accept a pasted operation URL as well as a base, retaining the gateway prefix.
        if base.path.hasSuffix("/chat/completions") {
            base.deleteLastPathComponent()
            base.deleteLastPathComponent()
        } else if ["models", "messages", "responses"].contains(base.lastPathComponent) {
            base.deleteLastPathComponent()
        }
        if (base.path.isEmpty || base.path == "/") && provider.kind != .deepSeek {
            base.appendPathComponent("v1")
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = body == nil ? 30 : 240
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.kind == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "x-api-key") }
        } else if !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> JSON {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else { throw APIError("未收到有效的 HTTP 响应。") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        guard (200...299).contains(http.statusCode) else {
            let error = object?["error"] as? JSON
            let detail = error?["message"] as? String ?? object?["message"] as? String ?? object?["detail"] as? String
            let hint: String
            switch http.statusCode {
            case 401, 403: hint = "请检查 API Key 和访问权限。"
            case 402: hint = "请检查服务商账户余额。"
            case 404: hint = "请检查 Base URL 和模型编号。"
            case 429: hint = "请求受限，请稍后重试或检查额度。"
            default: hint = "请检查所选模型、搜索和思考设置。"
            }
            let description = detail.map { String($0.prefix(500)) } ?? hint
            throw APIError("HTTP \(http.statusCode) · \(description)", status: http.statusCode, code: error?["code"] as? String)
        }
        guard let object else { throw APIError("服务商返回的内容不是 JSON，请检查 Base URL。") }
        return object
    }

    private static let redirectDelegate = SameOriginRedirects()

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let from = task.originalRequest?.url, let to = request.url,
                  from.scheme?.lowercased() == to.scheme?.lowercased(), from.host?.lowercased() == to.host?.lowercased(),
                  from.port == to.port else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
}
