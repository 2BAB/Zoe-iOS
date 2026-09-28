import Foundation
import FoundationModels

/// The Gemini API as a Foundation Models provider, authenticated with a Google AI Studio key.
///
/// Implementing `LanguageModel` lets the builder use Gemini through the same `LanguageModelSession`,
/// tools, and profile as the on-device model and Private Cloud Compute. Saved workflows never use it.
struct GeminiLanguageModel: LanguageModel {
    typealias Executor = GeminiExecutor

    let executorConfiguration: GeminiExecutor.Configuration

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .guidedGeneration, .reasoning])
    }

    init(apiKey: String, model: String = "gemini-3.8-flash") {
        executorConfiguration = .init(apiKey: apiKey, model: model)
    }
}

struct GeminiExecutor: LanguageModelExecutor {
    typealias Model = GeminiLanguageModel

    struct Configuration: Hashable, Sendable {
        var apiKey: String
        var model: String
    }

    let configuration: Configuration

    init(configuration: Configuration) throws {
        guard !configuration.apiKey.isEmpty else { throw ZoeError("Enter a Gemini API key from Google AI Studio.") }
        guard configuration.model.range(of: #"^[a-z0-9.\-]+$"#, options: .regularExpression) != nil else {
            throw ZoeError("“\(configuration.model)” isn't a valid Gemini model name.")
        }
        self.configuration = configuration
    }

    func respond(to request: LanguageModelExecutorGenerationRequest, model: GeminiLanguageModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.model):generateContent"
        var urlRequest = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 120)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try GeminiWire.requestBody(for: request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GeminiWire.error(status: status, body: data) }
        let reply = try GeminiWire.parse(data)

        // Gemini attaches a thought signature to its first function call and requires it back
        // on the next turn. Stored as a reasoning entry, it returns to us in the transcript.
        if let signature = reply.signature {
            await channel.send(.reasoning(action: .updateSignature(Data(signature.utf8), tokenCount: 0)))
        }
        let callsID = UUID().uuidString, responseID = UUID().uuidString
        for call in reply.calls {
            await channel.send(.toolCalls(entryID: callsID, action: .toolCall(
                id: call.id, name: call.name, action: .appendArguments(call.arguments, tokenCount: 0))))
        }
        if !reply.text.isEmpty {
            await channel.send(.response(entryID: responseID, action: .appendText(reply.text, tokenCount: 0)))
        }
        let input = LanguageModelExecutorGenerationChannel.Usage.Input(
            totalTokenCount: reply.inputTokens, cachedTokenCount: reply.cachedTokens)
        let output = LanguageModelExecutorGenerationChannel.Usage.Output(
            totalTokenCount: reply.outputTokens, reasoningTokenCount: reply.reasoningTokens)
        if reply.calls.isEmpty {
            await channel.send(.response(entryID: responseID, action: .updateUsage(input: input, output: output)))
        } else {
            await channel.send(.toolCalls(entryID: callsID, action: .updateUsage(input: input, output: output)))
        }
    }
}

/// Translation between Foundation Models types and the Gemini REST format (`generateContent`).
enum GeminiWire {
    struct Reply {
        struct Call { var id: String; var name: String; var arguments: String }
        var text = ""
        var calls: [Call] = []
        var signature: String?
        var inputTokens = 0, cachedTokens = 0, outputTokens = 0, reasoningTokens = 0
    }

    static func requestBody(for request: LanguageModelExecutorGenerationRequest) throws -> Data {
        var system: [String] = []
        var contents: [[String: Any]] = []
        var pendingSignature: String?

        func append(_ part: [String: Any], role: String) {
            if contents.last?["role"] as? String == role {
                var last = contents.removeLast()
                last["parts"] = (last["parts"] as? [[String: Any]] ?? []) + [part]
                contents.append(last)
            } else {
                contents.append(["role": role, "parts": [part]])
            }
        }

        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                system.append(try text(instructions.segments, in: entry))
            case .prompt(let prompt):
                append(["text": try text(prompt.segments, in: entry)], role: "user")
            case .response(let response):
                append(["text": try text(response.segments, in: entry)], role: "model")
            case .reasoning(let reasoning):
                pendingSignature = reasoning.signature.map { String(decoding: $0, as: UTF8.self) }
            case .toolCalls(let calls):
                for (index, call) in calls.enumerated() {
                    var part: [String: Any] = ["functionCall": [
                        "id": call.id, "name": call.toolName, "args": try json(call.arguments.jsonString),
                    ]]
                    if index == 0, let signature = pendingSignature { part["thoughtSignature"] = signature }
                    append(part, role: "model")
                }
                pendingSignature = nil
            case .toolOutput(let output):
                let result = try text(output.segments, in: entry)
                let response = (try? json(result)) as? [String: Any] ?? ["result": result]
                append(["functionResponse": ["id": output.id, "name": output.toolName, "response": response]],
                       role: "user")
            @unknown default:
                throw unsupported(entry, "This transcript entry isn't supported.")
            }
        }

        var body: [String: Any] = ["contents": contents]
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system.joined(separator: "\n\n")]]] }

        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = [["functionDeclarations": try request.enabledToolDefinitions.map { tool in
                ["name": tool.name, "description": tool.description,
                 "parametersJsonSchema": try jsonSchema(tool.parameters)]
            }]]
        }
        if let mode = request.generationOptions.toolCallingMode {
            let name = switch mode.kind { case .required: "ANY"; case .disallowed: "NONE"; default: "AUTO" }
            body["toolConfig"] = ["functionCallingConfig": ["mode": name]]
        }

        var config: [String: Any] = [:]
        if let schema = request.schema {
            config["responseMimeType"] = "application/json"
            config["responseJsonSchema"] = try jsonSchema(schema)
        }
        if let tokens = request.generationOptions.maximumResponseTokens { config["maxOutputTokens"] = tokens }
        if let temperature = request.generationOptions.temperature { config["temperature"] = temperature }
        if let level = request.contextOptions.reasoningLevel {
            let name = switch level { case .light: "LOW"; case .moderate: "MEDIUM"; default: "HIGH" }
            config["thinkingConfig"] = ["thinkingLevel": name]
        }
        if !config.isEmpty { body["generationConfig"] = config }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parse(_ data: Data) throws -> Reply {
        let root = try json(String(decoding: data, as: UTF8.self)) as? [String: Any] ?? [:]
        if let reason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            throw guardrail("Gemini blocked the prompt (\(reason)).")
        }
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else {
            throw ZoeError("Gemini returned no candidates.")
        }
        if let reason = candidate["finishReason"] as? String,
           ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(reason) {
            throw guardrail("Gemini stopped for safety (\(reason)).")
        }

        var reply = Reply()
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for part in parts {
            if let signature = part["thoughtSignature"] as? String, reply.signature == nil {
                reply.signature = signature
            }
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                let arguments = try JSONSerialization.data(withJSONObject: call["args"] ?? [String: Any]())
                reply.calls.append(.init(id: call["id"] as? String ?? UUID().uuidString, name: name,
                                         arguments: String(decoding: arguments, as: UTF8.self)))
            } else if let text = part["text"] as? String, part["thought"] as? Bool != true {
                reply.text += text
            }
        }
        let usage = root["usageMetadata"] as? [String: Any] ?? [:]
        reply.inputTokens = usage["promptTokenCount"] as? Int ?? 0
        reply.cachedTokens = usage["cachedContentTokenCount"] as? Int ?? 0
        reply.outputTokens = usage["candidatesTokenCount"] as? Int ?? 0
        reply.reasoningTokens = usage["thoughtsTokenCount"] as? Int ?? 0
        return reply
    }

    static func error(status: Int, body: Data) -> any Error {
        let message = ((try? json(String(decoding: body, as: UTF8.self))) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? "No details."
        if status == 429 {
            return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: message))
        }
        return ZoeError("Gemini returned HTTP \(status): \(message)")
    }

    /// Foundation Models encodes schemas as JSON Schema; Gemini names the ordering key differently.
    static func jsonSchema(_ schema: GenerationSchema) throws -> Any {
        let encoded = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
        return try json(encoded.replacingOccurrences(of: "\"x-order\"", with: "\"propertyOrdering\""))
    }

    private static func json(_ string: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(string.utf8), options: .fragmentsAllowed)
    }

    private static func text(_ segments: [Transcript.Segment], in entry: Transcript.Entry) throws -> String {
        try segments.map { segment in
            switch segment {
            case .text(let text): return text.content
            case .structure(let structure): return structure.content.jsonString
            default: throw unsupported(entry, "Only text and structured content are sent to Gemini.")
            }
        }.joined(separator: "\n")
    }

    private static func unsupported(_ entry: Transcript.Entry, _ message: String) -> LanguageModelError {
        .unsupportedTranscriptContent(.init(unsupportedContent: [entry], debugDescription: message))
    }

    private static func guardrail(_ message: String) -> LanguageModelError {
        .guardrailViolation(.init(debugDescription: message))
    }
}
