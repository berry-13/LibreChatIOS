import CryptoKit
import Foundation

public enum LibreChatGenerationIdentity {
    private static let newConversationNamespace = UUID(
        uuidString: "d7f2518c-94b8-4fe8-97ad-2d4bdb2c9f43"
    )!

    public static func newConversationID(
        userID: String,
        clientRequestID: String
    ) -> String {
        uuidV5(
            name: "\(userID):\(clientRequestID)",
            namespace: newConversationNamespace
        ).uuidString.lowercased()
    }

    private static func uuidV5(name: String, namespace: UUID) -> UUID {
        var namespaceUUID = namespace.uuid
        let namespaceBytes = withUnsafeBytes(of: &namespaceUUID) { Array($0) }
        var input = Data(namespaceBytes)
        input.append(contentsOf: name.utf8)

        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
