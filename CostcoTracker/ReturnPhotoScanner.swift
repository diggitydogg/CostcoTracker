import Foundation
import UIKit
import Vision
import ImageIO

// What we recognized from a package photo. The packaging barcode is NOT assumed
// to be the same as Costco's internal item number or receipt barcode.
struct ReturnPhotoScan {
    let recognizedLines: [String]
    let packageBarcodes: [String]
    let searchTerms: [String]
}

enum ReturnPhotoScanner {

    // Uses Apple's on-device Vision framework. The original camera photo stays
    // in memory; this function never saves it to Photos.
    static func scan(
        image: UIImage,
        completion: @escaping (Result<ReturnPhotoScan, Error>) -> Void
    ) {
        guard let cgImage = image.cgImage else {
            DispatchQueue.main.async {
                completion(.failure(ScanError.missingImage))
            }
            return
        }

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let barcodeRequest = VNDetectBarcodesRequest()
        let orientation = imageOrientation(image.imageOrientation)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handler = VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: orientation,
                    options: [:]
                )
                try handler.perform([textRequest, barcodeRequest])

                let lines = (textRequest.results ?? []).compactMap {
                    $0.topCandidates(1).first?.string
                }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

                let barcodes = Array(Set((barcodeRequest.results ?? []).compactMap {
                    $0.payloadStringValue
                })).sorted()

                let result = ReturnPhotoScan(
                    recognizedLines: lines,
                    packageBarcodes: barcodes,
                    searchTerms: searchTerms(from: lines)
                )

                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    // Prefer distinctive words/models over label boilerplate. All suggestions
    // still require the user to confirm the exact product and package size.
    private static func searchTerms(from lines: [String]) -> [String] {
        let ignored: Set<String> = [
            "THE", "AND", "WITH", "FOR", "FROM", "THIS", "THAT", "YOUR",
            "NET", "WEIGHT", "WT", "OZ", "LBS", "MADE", "USA", "PRODUCT",
            "WARNING", "CAUTION", "DIRECTIONS", "INGREDIENTS", "NUTRITION",
            "FACTS", "SERVING", "SERVINGS", "DISTRIBUTED", "EXPIRATION",
            "BEST", "BEFORE", "COSTCO", "KIRKLAND", "SIGNATURE", "ITEM",
            "QUALITY", "CONTENTS", "CONTAINS", "PACKAGING", "WWW", "COM"
        ]
        var seen = Set<String>()
        var terms: [String] = []

        for line in lines {
            let words = line.uppercased().components(
                separatedBy: CharacterSet.alphanumerics.inverted
            )
            for word in words {
                let hasLetter = word.unicodeScalars.contains {
                    CharacterSet.letters.contains($0)
                }
                let isModel = word.unicodeScalars.contains {
                    CharacterSet.decimalDigits.contains($0)
                }
                let minimumLength = isModel ? 3 : 4
                guard hasLetter, word.count >= minimumLength,
                      !ignored.contains(word), seen.insert(word).inserted else {
                    continue
                }
                terms.append(word)
                if terms.count == 12 { return terms }
            }
        }
        return terms
    }

    private static func imageOrientation(
        _ orientation: UIImage.Orientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private enum ScanError: LocalizedError {
        case missingImage

        var errorDescription: String? {
            "The camera image could not be read. Please try again."
        }
    }
}
