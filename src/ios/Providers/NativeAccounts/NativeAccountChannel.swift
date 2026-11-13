import Foundation

/// Native vendor transport, used before OpenAIProvider's URL construction/debug logging.
/// Only the normalized events are passed to the existing text/reasoning/tool parser.
struct NativeAccountChannel: Sendable {
    let instanceId: String
    let type: ProviderType

    func stream(body: [String: Any]) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        try await stream(body: body, retryAuth: true)
    }

    private func stream(body: [String: Any], retryAuth: Bool) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        let token = try await NativeAccountOAuthManager.shared.validToken(instanceId: instanceId, type: type)
        var shaped = body
        let url: URL
        var headers: [String: String]
        if type == .raccoon {
            url = RaccoonSite.work.chatURL!
            headers = RaccoonWire.requestHeaders(token: token.accessToken, orgCode: token.orgCode)
            headers["User-Agent"] = RaccoonSite.work.userAgent
            let limit = shaped.removeValue(forKey: "max_completion_tokens") as? Int ?? shaped["max_tokens"] as? Int
            shaped["max_tokens"] = RaccoonWire.clampOutputTokens(limit)
            let effort = shaped.removeValue(forKey: "reasoning_effort") as? String
            shaped.removeValue(forKey: "reasoning")
            if let effort, effort != "none", effort != "off" {
                var extra = shaped["extra_body"] as? [String: Any] ?? [:]
                extra["thinking"] = ["type": "enabled"]
                shaped["extra_body"] = extra
            }
        } else {
            // Resolve from this account's own roster. Never use a different account's cache.
            var functions = token.modelFunctions
            let modelID = body["model"] as? String ?? TraeWire.defaultModel
            if functions[modelID] == nil {
                _ = try await NativeAccountModels.fetch(instanceId: instanceId, type: type)
                functions = await NativeAccountOAuthManager.shared.token(instanceId: instanceId)?.modelFunctions ?? [:]
            }
            let origin = type.traeSite.origin(base: nil)
            url = TraeWire.chatURL(origin: origin)!
            headers = TraeWire.clientHeaders().merging(TraeWire.accountHeaders(token: token.accessToken,
                userID: token.userID, machineID: token.machineID, deviceID: token.deviceID)) { _, new in new }
            TraeWire.mending(&shaped, function: functions[modelID] ?? TraeWire.defaultFunction)
        }
        shaped["stream"] = true
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: shaped, options: [.sortedKeys])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        let session = URLSession(configuration: config)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { session.invalidateAndCancel(); throw error }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 && retryAuth {
            session.invalidateAndCancel()
            _ = try await NativeAccountOAuthManager.shared.validToken(instanceId: instanceId, type: type, forceRefresh: true)
            return try await stream(body: body, retryAuth: false)
        }
        guard (200..<300).contains(status) else {
            session.invalidateAndCancel()
            // Vendor error bodies can contain credentials. Do not forward/log them.
            throw LLMError.providerError(message: "\(type.displayName) request failed (HTTP \(status)).")
        }
        let isTrae = type != .raccoon
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var state = NativeAccountSSEState(isTrae: isTrae)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for out in try state.consume(line) { continuation.yield(out) }
                        if state.streamEnded { break }
                    }
                    for out in try state.finish() { continuation.yield(out) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
        }
        return (lines, status)
    }

    func streamMessage(model: LLMModel, messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        var serialized = messages.map(OpenAIProvider.openAIMessageDict)
        if let systemPrompt, !systemPrompt.isEmpty { serialized.insert(["role": "system", "content": systemPrompt], at: 0) }
        var body: [String: Any] = ["model": model.id, "messages": serialized, "max_tokens": maxTokens, "stream": true]
        if let temperature { body["temperature"] = temperature }
        let (lines, _) = try await stream(body: body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.started)
                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                        if let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String { continuation.yield(.text(text)) }
                        if let usage = json["usage"] as? [String: Any] {
                            continuation.yield(.usage(LLMUsage(inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                                outputTokens: usage["completion_tokens"] as? Int ?? 0)))
                        }
                        if let reason = (json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String {
                            continuation.yield(.finished(stopReason: reason))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Incremental SSE normalizer. A finish reason closes the turn, not the transport:
/// Raccoon may send a separate usage frame after it.
struct NativeAccountSSEState {
    let isTrae: Bool
    private(set) var streamEnded = false
    private(set) var finishSeen = false
    private var event = ""
    private var data: [String] = []
    private var answered = false
    private var calledTools = false
    private var doneEmitted = false
    private var tools = NativeAccountToolState()

    mutating func consume(_ line: String) throws -> [String] {
        guard !streamEnded else { return [] }
        if line.hasPrefix("event:") {
            let flushed = try flush()
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return flushed
        }
        if line.hasPrefix("data:") {
            data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            // AsyncBytes.lines can omit blank lines. Vendors send a complete JSON
            // document per data line; still retain fragments for multiline SSE.
            let joined = data.joined(separator: "\n")
            if joined == "[DONE]" || (try? JSONSerialization.jsonObject(with: Data(joined.utf8))) != nil {
                return try flush()
            }
        }
        if line.isEmpty { return try flush() }
        return []
    }

    private mutating func flush() throws -> [String] {
        guard !data.isEmpty else { return [] }
        let payload = data.joined(separator: "\n")
        let frameEvent = event
        data.removeAll(keepingCapacity: true)
        event = "" // Event names belong to one frame only, including unnamed frames.
        if payload == "[DONE]" {
            var out = finishTurn(reason: calledTools ? "tool_calls" : "stop")
            streamEnded = true
            if !doneEmitted { out.append("data: [DONE]"); doneEmitted = true }
            return out
        }
        guard var json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            throw LLMError.providerError(message: "The service returned a malformed stream frame.")
        }
        if isTrae {
            if let calls = json["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                calledTools = true
                json["tool_calls"] = tools.normalize(calls)
            }
            let encoded = try JSONSerialization.data(withJSONObject: json)
            let translated = TraeWire.translated(event: frameEvent, data: String(decoding: encoded, as: UTF8.self))
            if translated.failed {
                throw LLMError.providerError(message: "Trae refused the streaming request. Check the account and model.")
            }
            answered = answered || translated.answers
            if translated.ends {
                let raw = TraeWire.finishReason(json["finish_reason"] as? String)
                return finishTurn(reason: calledTools && raw == "stop" ? "tool_calls" : raw)
            }
            return translated.lines.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
        }
        if json["error"] != nil || RaccoonWire.envelopeError(json) != nil {
            throw LLMError.providerError(message: "Raccoon refused the streaming request. Check account credits and access.")
        }
        if var choices = json["choices"] as? [[String: Any]], !choices.isEmpty {
            var choice = choices[0]
            if var delta = choice["delta"] as? [String: Any] {
                if let calls = delta["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    calledTools = true
                    delta["tool_calls"] = tools.normalize(calls)
                    choice["delta"] = delta
                }
                answered = answered || (delta["content"] as? String)?.isEmpty == false
                    || (delta["reasoning_content"] as? String)?.isEmpty == false || calledTools
            }
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                if finishSeen { choice["finish_reason"] = NSNull() }
                else {
                    finishSeen = true
                    if calledTools && reason == "stop" { choice["finish_reason"] = "tool_calls" }
                }
            }
            choices[0] = choice
            json["choices"] = choices
        }
        return [String(decoding: TraeWire.sseData(json), as: UTF8.self).trimmingCharacters(in: .newlines)]
    }

    private mutating func finishTurn(reason: String) -> [String] {
        guard !finishSeen else { return [] }
        finishSeen = true
        return [String(decoding: TraeWire.finishFrame(reason), as: UTF8.self).trimmingCharacters(in: .newlines)]
    }

    mutating func finish() throws -> [String] {
        var out = try flush()
        if !finishSeen {
            guard answered || calledTools else {
                throw LLMError.providerError(message: "The service ended without an answer.")
            }
            out += finishTurn(reason: calledTools ? "tool_calls" : "length")
        }
        streamEnded = true
        if !doneEmitted { out.append("data: [DONE]"); doneEmitted = true }
        return out
    }
}

/// Feed the existing OpenAI parser stable indices and exactly one id/name start.
/// Vendors can repeat metadata, omit indices, or split metadata from arguments.
private struct NativeAccountToolState {
    private struct Call {
        var id = ""
        var name = ""
        var pendingArguments = ""
        var started = false
    }
    private var calls: [Int: Call] = [:]
    private var indicesByID: [String: Int] = [:]
    private var lastIndex: Int?

    mutating func normalize(_ incoming: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for (position, raw) in incoming.enumerated() {
            let function = (raw["function_call"] ?? raw["function"]) as? [String: Any] ?? [:]
            let id = raw["id"] as? String ?? ""
            let name = function["name"] as? String ?? ""
            let index: Int
            if let explicit = (raw["index"] as? NSNumber)?.intValue { index = explicit }
            else if !id.isEmpty, let known = indicesByID[id] { index = known }
            else if !id.isEmpty { index = (calls.keys.max() ?? -1) + 1 }
            else if incoming.count > 1 { index = position }
            else if !name.isEmpty, let known = calls.first(where: { $0.value.name == name })?.key { index = known }
            else { index = lastIndex ?? 0 }
            var call = calls[index] ?? Call()
            if !id.isEmpty { indicesByID[id] = index; if !call.started { call.id = id } }
            if !name.isEmpty && !call.started { call.name = name }
            if let arguments = function["arguments"] as? String {
                call.pendingArguments += arguments
            } else if let arguments = function["arguments"], !(arguments is NSNull),
                      JSONSerialization.isValidJSONObject(arguments),
                      let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) {
                call.pendingArguments += String(decoding: data, as: UTF8.self)
            }
            if !call.name.isEmpty {
                var fields: [String: Any] = [:]
                var entry: [String: Any] = ["index": index, "type": "function"]
                if !call.started {
                    if call.id.isEmpty { call.id = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
                    entry["id"] = call.id
                    fields["name"] = call.name
                    call.started = true
                }
                if !call.pendingArguments.isEmpty {
                    fields["arguments"] = call.pendingArguments
                    call.pendingArguments = ""
                }
                if !fields.isEmpty { entry["function"] = fields; result.append(entry) }
            }
            calls[index] = call
            lastIndex = index
        }
        return result
    }
}

@MainActor
enum NativeAccountModels {
    static func fetch(instanceId: String, type: ProviderType) async throws -> [LLMModel] {
        let token = try await NativeAccountOAuthManager.shared.validToken(instanceId: instanceId, type: type)
        if type == .raccoon {
            let entries = await RaccoonWire.catalog(site: .work,
                token: .init(value: token.accessToken, orgCode: token.orgCode))
            guard !entries.isEmpty else { throw LLMError.providerError(message: "Raccoon returned no available models.") }
            return entries.map { entry in
                var model = LLMModel(id: entry.id, displayName: entry.name, provider: type.displayName,
                    modalityOverride: entry.supportsImage ? [.textInput, .textOutput, .imageInput] : .textOnly,
                    contextWindow: entry.contextWindow, maxOutputTokens: entry.maxTokens,
                    supportsReasoning: true, interleavedReasoningField: "reasoning_content", declaresNoEffortTiers: true)
                model.limitsReportedByEndpoint = true
                return model
            }
        }
        let entries = await TraeWire.roster(origin: type.traeSite.origin(base: nil), token: .init(value: token.accessToken,
            userID: token.userID, machineID: token.machineID, deviceID: token.deviceID))
        guard !entries.isEmpty else { throw LLMError.providerError(message: "Trae returned no available models.") }
        // Preserve the function which actually published each model across process restarts.
        if var current = NativeAccountOAuthManager.shared.token(instanceId: instanceId), current.accessToken == token.accessToken {
            current.modelFunctions = Dictionary(entries.map { ($0.id, $0.function) }, uniquingKeysWith: { first, _ in first })
            ProviderKeychainHelper.saveOAuthToken(current, instanceId: instanceId)
        }
        return entries.map { entry in
            var model = LLMModel(id: entry.id, displayName: entry.id, provider: type.displayName,
                modalityOverride: .textOnly, contextWindow: entry.contextWindow, maxOutputTokens: entry.maxTokens,
                supportsReasoning: entry.reasoning, interleavedReasoningField: "reasoning_content")
            model.limitsReportedByEndpoint = true
            return model
        }
    }
}
