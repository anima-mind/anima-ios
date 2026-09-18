import Foundation
import Testing
@testable import AnimaKit

@Suite struct SSEParserTests {

    /// Secuencia realista: thinking, texto, tool_use con input_json_delta fragmentado,
    /// un ping (ignorado), y message_delta con stop_reason tool_use + usage.
    static let toolUseStream = """
    data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_read_input_tokens":5}}}
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pens"}}
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ando"}}
    data: {"type":"content_block_stop","index":0}
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text"}}
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hola"}}
    data: {"type":"content_block_stop","index":1}
    data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"notes"}}
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"action\\":"}}
    data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\\"list\\"}"}}
    data: {"type":"content_block_stop","index":2}
    data: {"type":"ping"}
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}
    data: {"type":"message_stop"}
    """

    @Test func parsesRealisticToolUseStream() throws {
        let events = try SSEParser.parse(raw: Self.toolUseStream)

        #expect(events == [
            .messageStart(id: "msg_1", model: "claude-opus-4-8"),
            .thinkingDelta("pens"),
            .thinkingDelta("ando"),
            .blockStop(index: 0),
            .textDelta("Hola"),
            .blockStop(index: 1),
            .toolUseStart(id: "toolu_1", name: "notes"),
            .toolUseInputDelta("{\"action\":"),
            .toolUseInputDelta("\"list\"}"),
            .blockStop(index: 2),
            .messageDelta(stopReason: .toolUse,
                          usage: Usage(inputTokens: 10, outputTokens: 20,
                                       cacheReadInputTokens: 5, cacheCreationInputTokens: nil)),
            .messageStop,
        ])
    }

    @Test func ignoresUnknownEventsAndKeepAlives() throws {
        let raw = """
        event: message_start
        data: {"type":"desconocido_del_futuro","foo":42}
        data: {"type":"ping"}
        : keep-alive comment
        data: {"type":"message_stop"}
        """
        let events = try SSEParser.parse(raw: raw)
        #expect(events == [.messageStop])
    }

    @Test func parsesPauseTurn() throws {
        let raw = """
        data: {"type":"message_delta","delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":3}}
        """
        let events = try SSEParser.parse(raw: raw)
        #expect(events == [.messageDelta(stopReason: .pauseTurn, usage: Usage(outputTokens: 3))])
    }

    @Test func errorEventThrowsClassified() {
        let raw = #"data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}"#
        #expect(throws: ClassifiedError.self) {
            _ = try SSEParser.parse(raw: raw)
        }
    }

    @Test func collectingBuildsResponseWithParsedToolInput() async throws {
        let events = try SSEParser.parse(raw: Self.toolUseStream)
        let provider = MockProvider(events: events)
        let opts = try TestConfig.callOpts(authMode: .apiKey)

        let response = try await provider.completeCollecting(
            AssembledContext(messages: []), tools: [], opts: opts)

        #expect(response.id == "msg_1")
        #expect(response.stopReason == .toolUse)
        #expect(response.usage.inputTokens == 10)
        #expect(response.usage.outputTokens == 20)
        #expect(response.usage.cacheReadInputTokens == 5)
        #expect(response.content == [
            .thinking("pensando"),
            .text("Hola"),
            .toolUse(id: "toolu_1", name: "notes",
                     input: .object(["action": .string("list")])),
        ])
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "notes")
    }
}
