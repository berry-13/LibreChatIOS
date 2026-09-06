import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum CameraCaptureAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum CameraCaptureAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

enum CameraCaptureAccessDecision: Equatable, Sendable {
    case present
    case requestPermission
    case unavailable
    case denied
    case restricted
}

struct CameraCapturePolicy: Sendable {
    static func decision(
        availability: CameraCaptureAvailability,
        authorization: CameraCaptureAuthorization
    ) -> CameraCaptureAccessDecision {
        guard availability == .available else { return .unavailable }
        switch authorization {
        case .authorized:
            return .present
        case .notDetermined:
            return .requestPermission
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        }
    }
}

struct CameraCapturePresentation: Identifiable, Equatable {
    let id = UUID()
}

struct CameraCaptureAccessIssue: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case unavailable
        case denied
        case restricted
    }

    let kind: Kind

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .unavailable:
            return "Camera unavailable"
        case .denied:
            return "Camera access is off"
        case .restricted:
            return "Camera access is restricted"
        }
    }

    var message: String {
        switch kind {
        case .unavailable:
            return "This device cannot take a photo right now. You can still choose one from the photo library."
        case .denied:
            return "Allow camera access in Settings to take a photo for this chat."
        case .restricted:
            return "Camera access is restricted on this device. You can still choose a photo from the library."
        }
    }

    var offersSettings: Bool { kind == .denied }
}

@MainActor
enum SystemCameraCaptureAccess {
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static func prepare() async -> CameraCaptureAccessDecision {
        let initial = CameraCapturePolicy.decision(
            availability: isCameraAvailable ? .available : .unavailable,
            authorization: authorization
        )
        guard initial == .requestPermission else { return initial }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        return allowed ? .present : .denied
    }

    private static var authorization: CameraCaptureAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }
}

struct CapturedCameraPhoto: Equatable, Sendable {
    let data: Data
    let filename: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
}

enum CameraCaptureFailure: LocalizedError, Equatable {
    case missingImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "The camera did not return a photo. Please try again."
        case .encodingFailed:
            return "That photo could not be prepared for upload. Please try again."
        }
    }
}

@MainActor
struct CameraPhotoEncoder {
    static let defaultMaximumPixelDimension: CGFloat = 4_096
    static let defaultCompressionQuality: CGFloat = 0.88

    static func encode(
        _ image: UIImage,
        maximumPixelDimension: CGFloat = defaultMaximumPixelDimension,
        compressionQuality: CGFloat = defaultCompressionQuality,
        identifier: UUID = UUID()
    ) throws -> CapturedCameraPhoto {
        guard image.size.width > 0,
              image.size.height > 0,
              maximumPixelDimension > 0,
              (0...1).contains(compressionQuality) else {
            throw CameraCaptureFailure.encodingFailed
        }

        // Encoding the original first lets ImageIO decode a bounded
        // thumbnail: drawing the full-resolution bitmap into the 4096-pixel
        // destination keeps both images resident (hundreds of MB on 48 MP
        // sensors).
        guard let originalData = image.jpegData(compressionQuality: 0.92),
              let source = CGImageSourceCreateWithData(originalData as CFData, nil) else {
            throw CameraCaptureFailure.encodingFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumPixelDimension),
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CameraCaptureFailure.encodingFailed
        }
        // The thumbnail carries the EXIF transform; report its pixels.
        let thumbnail = UIImage(cgImage: cgThumbnail)
        guard let data = thumbnail.jpegData(compressionQuality: compressionQuality), !data.isEmpty else {
            throw CameraCaptureFailure.encodingFailed
        }
        let pixelWidth = Int((thumbnail.size.width * thumbnail.scale).rounded())
        let pixelHeight = Int((thumbnail.size.height * thumbnail.scale).rounded())
        return CapturedCameraPhoto(
            data: data,
            filename: "camera-\(identifier.uuidString.lowercased()).jpg",
            mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg",
            pixelWidth: pixelWidth > 0 ? pixelWidth : Int(maximumPixelDimension),
            pixelHeight: pixelHeight > 0 ? pixelHeight : Int(maximumPixelDimension)
        )
    }
}

struct CameraCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let completed: (Result<CapturedCameraPhoto, CameraCaptureFailure>) -> Void

    var body: some View {
        CameraCaptureController { result in
            completed(result)
            dismiss()
        } cancelled: {
            dismiss()
        }
        .ignoresSafeArea()
    }
}

private struct CameraCaptureController: UIViewControllerRepresentable {
    let completed: (Result<CapturedCameraPhoto, CameraCaptureFailure>) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completed: completed, cancelled: cancelled)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.delegate = context.coordinator
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.mediaTypes = [UTType.image.identifier]
        controller.allowsEditing = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let completed: (Result<CapturedCameraPhoto, CameraCaptureFailure>) -> Void
        private let cancelled: () -> Void
        private var didFinish = false

        init(
            completed: @escaping (Result<CapturedCameraPhoto, CameraCaptureFailure>) -> Void,
            cancelled: @escaping () -> Void
        ) {
            self.completed = completed
            self.cancelled = cancelled
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !didFinish else { return }
            didFinish = true
            cancelled()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !didFinish else { return }
            didFinish = true
            guard let image = info[.originalImage] as? UIImage else {
                completed(.failure(.missingImage))
                return
            }
            do {
                completed(.success(try CameraPhotoEncoder.encode(image)))
            } catch let failure as CameraCaptureFailure {
                completed(.failure(failure))
            } catch {
                completed(.failure(.encodingFailed))
            }
        }
    }
}
