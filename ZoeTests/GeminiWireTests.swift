import Foundation
import FoundationModels
import Testing
@testable import Zoe

/// The Gemini provider can't be exercised without an API key, so these tests pin the wire format.
struct GeminiWireTests {
    @Generable struct OpenPageArguments { var url: String }

    @Test func translatesToolTurnAndReturnsThoughtSignature() throws {
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Be brief."))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Open the page."))])),
            .reasoning(.init(segments: [], signature: Data("sig-1".utf8))),
            .toolCalls(.init([.init(id: "call-1", toolName: "openPage",
                                    arguments: try GeneratedContent(json: #"{"url":"https://example.com"}"#))])),
            .toolOutput(.init(id: "call-1", toolName: "openPage", segments: [.text(.init(content: "Loaded."))])),
        ])
        let tool = Transcript.ToolDefinition(name: "openPage", description: "Opens a page.",
                                             parameters: OpenPageArguments.generationSchema)
        let request = LanguageModelExecutorGenerationRequest(
            id: UUID(), transcript: transcript, enabledTools: [tool],
            generationOptions: GenerationOptions(toolCallingMode: .required),
            contextOptions: ContextOptions(reasoningLevel: .deep), metadata: [:])

        let body = try #require(try JSONSerialization.jsonObject(with: GeminiWire.requestBody(for: request)) as? [String: Any])
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])

        let callPart = try #require((contents[1]["parts"] as? [[String: Any]])?.first)
        #expect(callPart["thoughtSignature"] as? String == "sig-1")
        let call = try #require(callPart["functionCall"] as? [String: Any])
        #expect(call["name"] as? String == "openPage")
        #expect((call["args"] as? [String: Any])?["url"] as? String == "https://example.com")

        let response = try #require((contents[2]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any])
        #expect((response["response"] as? [String: Any])?["result"] as? String == "Loaded.")

        let declarations = try #require((body["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]])
        let schema = try #require(declarations.first?["parametersJsonSchema"] as? [String: Any])
        #expect(schema["propertyOrdering"] as? [String] == ["url"])
        #expect(schema["x-order"] == nil)

        #expect(((body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])?["mode"] as? String == "ANY")
        #expect(((body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "HIGH")
        #expect((body["systemInstruction"] as? [String: Any]) != nil)
    }

    @Test func parsesFunctionCallsSignatureAndUsage() throws {
        let data = Data("""
            {"candidates":[{"content":{"role":"model","parts":[
              {"text":"thinking…","thought":true},
              {"functionCall":{"id":"c1","name":"inspect","args":{"selector":"body"}},"thoughtSignature":"sig-2"},
              {"functionCall":{"id":"c2","name":"openPage","args":{"url":"https://example.com/a"}}}
            ]},"finishReason":"STOP"}],
             "usageMetadata":{"promptTokenCount":120,"candidatesTokenCount":30,"thoughtsTokenCount":12}}
            """.utf8)
        let reply = try GeminiWire.parse(data)
        #expect(reply.signature == "sig-2")
        #expect(reply.calls.map(\.name) == ["inspect", "openPage"])
        #expect(reply.calls[0].arguments == #"{"selector":"body"}"#)
        #expect(reply.text.isEmpty)
        #expect((reply.inputTokens, reply.outputTokens, reply.reasoningTokens) == (120, 30, 12))
    }

    @Test func mapsSafetyStopsAndRateLimits() {
        let blocked = Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8)
        #expect(throws: LanguageModelError.self) { try GeminiWire.parse(blocked) }
        #expect(GeminiWire.error(status: 429, body: Data()) is LanguageModelError)
    }
}
