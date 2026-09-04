import Foundation
import LibreChatDomain

public struct AccountAvatarResponseDTO: Decodable, Equatable, Sendable {
    public var url: String?

    public init(url: String? = nil) {
        self.url = url
    }

    public func domainURL(relativeTo baseURL: URL) throws -> URL {
        let allowsLoopbackHTTP = baseURL.scheme?.lowercased() == "http"
        guard let resolved = TargetIconURLPolicy(
            allowsInsecureLoopback: allowsLoopbackHTTP
        ).resolve(url, relativeTo: baseURL) else {
            throw AccountProfileError.invalidAvatarResponse
        }
        return resolved.url
    }
}

public struct AccountDeletionResponseDTO: Decodable, Equatable, Sendable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public func validateConfirmation() throws {
        guard message == "User deleted" else {
            throw AccountDeletionError.invalidResponse
        }
    }
}

private struct AccountDeletionProofDTO: Encodable, Sendable {
    var token: String?
    var backupCode: String?

    init(_ proof: TwoFactorProof) {
        switch proof {
        case let .authenticatorCode(value):
            token = value
            backupCode = nil
        case let .backupCode(value):
            token = nil
            backupCode = value
        }
    }
}

public enum LibreChatAccountProfileAPI {
    public static let maximumAvatarBytes = 2 * 1_048_576

    public static func profile() -> APIRequest<LibreChatUserDTO> {
        APIRequest(
            path: "api/user",
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func uploadAvatar(
        _ upload: AccountAvatarUpload,
        boundary: String,
        maximumBytes: Int = maximumAvatarBytes
    ) throws -> APIRequest<AccountAvatarResponseDTO> {
        guard !upload.data.isEmpty else { throw AccountProfileError.invalidAvatar }
        guard maximumBytes > 0, upload.data.count <= maximumBytes else {
            throw AccountProfileError.avatarTooLarge(maximumBytes: maximumBytes)
        }
        guard boundary.range(
            of: #"^[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression
        ) != nil else {
            throw LibreChatProtocolError.encoding("The multipart boundary is invalid.")
        }

        let mimeType = upload.mimeType.lowercased()
        let filename: String
        switch mimeType {
        case "image/png" where upload.data.starts(with: [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
        ]):
            filename = "avatar.png"
        case "image/jpeg" where upload.data.starts(with: [0xFF, 0xD8, 0xFF]):
            filename = "avatar.jpg"
        default:
            throw AccountProfileError.unsupportedAvatarFormat
        }

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        )
        body.appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        body.append(upload.data)
        body.appendUTF8("\r\n--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"manual\"\r\n\r\n")
        body.appendUTF8("true\r\n")
        body.appendUTF8("--\(boundary)--\r\n")
        let multipartBody: Data? = body

        return APIRequest(
            method: .post,
            path: "api/files/images/avatar",
            headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
            body: multipartBody,
            authorization: .bearer,
            retryPolicy: .never
        )
    }

    public static func deleteAccount(
        proof: TwoFactorProof?
    ) throws -> APIRequest<AccountDeletionResponseDTO> {
        if let proof {
            return try APIRequest(
                method: .delete,
                path: "api/user/delete",
                body: AccountDeletionProofDTO(proof),
                authorization: .bearer,
                retryPolicy: .never
            )
        }
        return APIRequest(
            method: .delete,
            path: "api/user/delete",
            authorization: .bearer,
            retryPolicy: .never
        )
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}
