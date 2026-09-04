import ImageIO
import LibreChatDomain
import LibreChatProtocol
import XCTest
import UIKit
@testable import LibreChat

@MainActor
final class CameraCaptureTests: XCTestCase {
    func testAccessPolicyFailsClosedBeforeConsideringAuthorization() {
        for authorization in [
            CameraCaptureAuthorization.authorized,
            .notDetermined,
            .denied,
            .restricted,
        ] {
            XCTAssertEqual(
                CameraCapturePolicy.decision(
                    availability: .unavailable,
                    authorization: authorization
                ),
                .unavailable
            )
        }
    }

    func testAccessPolicyMapsEveryAvailableAuthorizationState() {
        XCTAssertEqual(
            CameraCapturePolicy.decision(availability: .available, authorization: .authorized),
            .present
        )
        XCTAssertEqual(
            CameraCapturePolicy.decision(availability: .available, authorization: .notDetermined),
            .requestPermission
        )
        XCTAssertEqual(
            CameraCapturePolicy.decision(availability: .available, authorization: .denied),
            .denied
        )
        XCTAssertEqual(
            CameraCapturePolicy.decision(availability: .available, authorization: .restricted),
            .restricted
        )
    }

    func testCapturedPhotoIsOrientationNormalizedBoundedJPEG() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        }
        let identifier = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))

        let photo = try CameraPhotoEncoder.encode(
            source,
            maximumPixelDimension: 40,
            compressionQuality: 0.9,
            identifier: identifier
        )

        XCTAssertEqual(photo.filename, "camera-00000000-0000-0000-0000-000000000123.jpg")
        XCTAssertEqual(photo.mimeType, "image/jpeg")
        XCTAssertEqual(photo.pixelWidth, 40)
        XCTAssertEqual(photo.pixelHeight, 20)
        XCTAssertFalse(photo.data.isEmpty)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(photo.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 40)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 20)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    func testInvalidEncodingPolicyFailsWithoutProducingAttachmentData() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }

        XCTAssertThrowsError(
            try CameraPhotoEncoder.encode(image, maximumPixelDimension: 0)
        ) { error in
            XCTAssertEqual(error as? CameraCaptureFailure, .encodingFailed)
        }
        XCTAssertThrowsError(
            try CameraPhotoEncoder.encode(image, compressionQuality: 1.1)
        ) { error in
            XCTAssertEqual(error as? CameraCaptureFailure, .encodingFailed)
        }
    }

    func testDeniedIssueOffersSettingsButUnavailableAndRestrictedDoNot() {
        XCTAssertTrue(CameraCaptureAccessIssue(kind: .denied).offersSettings)
        XCTAssertFalse(CameraCaptureAccessIssue(kind: .unavailable).offersSettings)
        XCTAssertFalse(CameraCaptureAccessIssue(kind: .restricted).offersSettings)
    }

    func testUploadRouteUsesImageProcessingExceptForAssistantsV2() {
        XCTAssertEqual(
            UploadManager.uploadPath(for: pendingUpload(endpoint: "agents", width: 640, height: 480)),
            "api/files/images"
        )
        XCTAssertEqual(
            UploadManager.uploadPath(for: pendingUpload(endpoint: "assistants", width: 640, height: 480)),
            "api/files"
        )
        XCTAssertEqual(
            UploadManager.uploadPath(for: pendingUpload(endpoint: "azureAssistants", width: 640, height: 480)),
            "api/files"
        )
        XCTAssertEqual(
            UploadManager.uploadPath(for: pendingUpload(endpoint: "agents")),
            "api/files"
        )
    }

    func testUploadAcknowledgementBindsTemporaryClientIDAndKeepsServerID() throws {
        let upload = pendingUpload(endpoint: "agents", width: 640, height: 480)
        let remote = UploadedFile(
            id: "server-generated-file-id",
            temporaryID: upload.id.uuidString,
            filename: "captured.jpg",
            mimeType: "image/jpeg",
            width: 640,
            height: 480
        )

        let completed = try UploadManager.completedUpload(upload, acknowledging: remote)

        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.progress, 1)
        XCTAssertEqual(completed.remoteIdentifier, "server-generated-file-id")
        XCTAssertEqual(completed.remoteFile, remote)
    }

    func testUploadAcknowledgementRejectsMissingOrForeignTemporaryID() {
        let upload = pendingUpload(endpoint: "agents", width: 640, height: 480)
        for temporaryID in [nil, "another-client-id"] {
            XCTAssertThrowsError(
                try UploadManager.completedUpload(
                    upload,
                    acknowledging: UploadedFile(
                        id: "server-generated-file-id",
                        temporaryID: temporaryID,
                        filename: "captured.jpg"
                    )
                )
            ) { error in
                XCTAssertEqual(error as? LibreChatProtocolError, .invalidResponse)
            }
        }
    }

    func testServerAdvertisedClientResizeBoundsImageAndConvertsToJPEG() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        let sourceData = try XCTUnwrap(source.pngData())
        let configuration = FileConfigurationDTO(
            clientImageResize: ClientImageResizeConfigurationDTO(
                enabled: true,
                maxWidth: 20,
                maxHeight: 20,
                quality: 0.8
            )
        )

        let prepared = try UploadManager.preparedUploadData(
            data: sourceData,
            mimeType: "image/png",
            configuration: configuration
        )

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 20)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 10)
    }

    func testDisabledClientResizeLeavesImageBytesAndMimeTypeUnchanged() throws {
        let original = Data([0x01, 0x02, 0x03])
        let prepared = try UploadManager.preparedUploadData(
            data: original,
            mimeType: "image/png",
            configuration: FileConfigurationDTO(
                clientImageResize: ClientImageResizeConfigurationDTO(enabled: false)
            )
        )

        XCTAssertEqual(prepared.data, original)
        XCTAssertEqual(prepared.mimeType, "image/png")
    }

    private func pendingUpload(
        endpoint: String,
        width: Int? = nil,
        height: Int? = nil
    ) -> PendingUpload {
        PendingUpload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversationID: ConversationID(rawValue: "conversation"),
            localURL: URL(fileURLWithPath: "/tmp/captured.jpg"),
            filename: "captured.jpg",
            mimeType: "image/jpeg",
            endpoint: endpoint,
            width: width,
            height: height
        )
    }
}
