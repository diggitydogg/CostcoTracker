
import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {

    @Binding var isPresented: Bool

    let onPhoto: (UIImage) -> Void

    func makeUIViewController(
        context: Context
    ) -> UIImagePickerController {

        let picker = UIImagePickerController()

        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo

        picker.allowsEditing = false

        picker.delegate = context.coordinator

        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject,
        UIImagePickerControllerDelegate,
        UINavigationControllerDelegate {

        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info:
                [UIImagePickerController.InfoKey: Any]
        ) {

            guard let image =
                info[.originalImage] as? UIImage
            else {
                parent.isPresented = false
                return
            }

            parent.isPresented = false

            // Send the picture directly to CostcoTracker.
            parent.onPhoto(image)
        }

        func imagePickerControllerDidCancel(
            _ picker: UIImagePickerController
        ) {

            parent.isPresented = false
        }
    }
}

