#if canImport(UIKit)
import SwiftUI
import UIKit

/// A minimal camera capture for OCR (PR 14), gated to UIKit. Optional by design — the
/// app works from an imported photo with no camera (`PhotosPicker`), so this is only
/// offered when a camera exists. Returns encoded JPEG `Data` (or nil on cancel) to the
/// common `OCRCaptureModel`, which never sees a `UIImage`.
///
/// NOT COMPILED HERE (no UIKit/Xcode on Linux). Correct-by-inspection; the camera
/// permission prompt (`NSCameraUsageDescription`) and capture are a device step.
struct OCRCamera: UIViewControllerRepresentable {
    /// Whether this device has a usable camera; the source picker hides the option
    /// otherwise, so a camera-less device (or denied hardware) degrades to import-only.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data?) -> Void
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
