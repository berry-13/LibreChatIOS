import Foundation
import Testing
@testable import LibreChatProtocol

struct SSEDecoderTests {
    @Test func splitAtEveryByteBoundary() throws {
        let payload = Data("event: message\nid: 42\nretry: 1500\ndata: {\"delta\":\"Hello\"}\n\n".utf8)
        var decoder = SSEDecoder()
        var events: [ServerSentEvent] = []
        for byte in payload { events.append(contentsOf: try decoder.append(Data([byte]))) }
        #expect(events == [ServerSentEvent(
            event: "message",
            id: "42",
            retry: 1500,
            data: "{\"delta\":\"Hello\"}"
        )])
    }

    @Test func multilineCommentsAndPartialTail() throws {
        var decoder = SSEDecoder()
        let first = try decoder.append(Data(": heartbeat\r\ndata: first\r\ndata: sec".utf8))
        let second = try decoder.append(Data("ond\r\n\r\n".utf8))
        #expect(first.isEmpty)
        #expect(second == [ServerSentEvent(data: "first\nsecond")])
    }
}
