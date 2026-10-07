import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import Vision


// MARK: - Costco Receipt Barcode

/// Costco warehouse receipts use Interleaved 2 of 5.
///
/// Costco may display an odd-length receipt identifier beneath
/// the barcode while the actual encoded barcode contains a
/// leading zero so the payload has an even number of digits.
///
/// Example:
///
/// Printed:
/// 12345678901234567890123
///
/// Encoded:
/// 012345678901234567890123
///
func costcoBarcodePayload(
    from receiptIdentifier: String
) -> String? {

    let trimmed =
        receiptIdentifier
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )


    guard
        !trimmed.isEmpty,
        trimmed.allSatisfy({
            $0 >= "0" &&
            $0 <= "9"
        })
    else {
        return nil
    }


    if (
        trimmed.count %
        2 == 0
    ) {

        return trimmed
    }


    return "0" + trimmed
}


/// Generates the barcode used on Costco warehouse receipts.
///
/// Numeric Costco receipt identifiers are rendered as
/// Interleaved 2 of 5.
///
/// Non-numeric identifiers fall back to Code 128 so existing
/// non-Costco/synthetic uses do not crash.
func generateBarcode(
    from string: String
) -> UIImage {

    if let payload =
        costcoBarcodePayload(
            from: string
        ),

       let image =
        generateInterleaved2of5Barcode(
            payload
        ) {

        return image
    }


    return generateCode128Barcode(
        from: string
    )
}


// MARK: - Interleaved 2 of 5

private func generateInterleaved2of5Barcode(
    _ digits: String
) -> UIImage? {

    guard
        !digits.isEmpty,
        digits.count % 2 == 0
    else {
        return nil
    }


    // Interleaved 2 of 5 digit patterns.
    //
    // n = narrow
    // w = wide
    //
    // For each pair of digits:
    // first digit controls the bars,
    // second digit controls the spaces.

    let patterns:
        [Character: String] = [

            "0": "nnwwn",
            "1": "wnnnw",
            "2": "nwnnw",
            "3": "wwnnn",
            "4": "nnwnw",
            "5": "wnwnn",
            "6": "nwwnn",
            "7": "nnnww",
            "8": "wnnwn",
            "9": "nwnwn"
        ]


    struct Element {

        let isBar: Bool
        let isWide: Bool
    }


    var elements:
        [Element] = []


    // Standard I2of5 start pattern:
    //
    // narrow bar
    // narrow space
    // narrow bar
    // narrow space

    elements.append(
        Element(
            isBar: true,
            isWide: false
        )
    )

    elements.append(
        Element(
            isBar: false,
            isWide: false
        )
    )

    elements.append(
        Element(
            isBar: true,
            isWide: false
        )
    )

    elements.append(
        Element(
            isBar: false,
            isWide: false
        )
    )


    let characters =
        Array(digits)


    var index =
        0


    while (
        index <
        characters.count
    ) {

        let firstDigit =
            characters[index]

        let secondDigit =
            characters[
                index + 1
            ]


        guard
            let firstPattern =
                patterns[
                    firstDigit
                ],

            let secondPattern =
                patterns[
                    secondDigit
                ]
        else {
            return nil
        }


        let barPattern =
            Array(
                firstPattern
            )

        let spacePattern =
            Array(
                secondPattern
            )


        for patternIndex
            in 0..<5 {

            elements.append(
                Element(
                    isBar: true,
                    isWide:
                        barPattern[
                            patternIndex
                        ] == "w"
                )
            )


            elements.append(
                Element(
                    isBar: false,
                    isWide:
                        spacePattern[
                            patternIndex
                        ] == "w"
                )
            )
        }


        index +=
            2
    }


    // Standard I2of5 stop pattern:
    //
    // wide bar
    // narrow space
    // narrow bar

    elements.append(
        Element(
            isBar: true,
            isWide: true
        )
    )

    elements.append(
        Element(
            isBar: false,
            isWide: false
        )
    )

    elements.append(
        Element(
            isBar: true,
            isWide: false
        )
    )


    // MARK: Rendering Dimensions

    // Use integer-width modules so the edges remain
    // crisp when the image is generated.

    let narrowWidth:
        CGFloat = 4

    let wideMultiplier:
        CGFloat = 3

    let wideWidth =
        narrowWidth *
        wideMultiplier


    // I2of5 quiet zone should be at least
    // ten narrow modules on each side.

    let quietZone =
        narrowWidth *
        10


    let barcodeHeight:
        CGFloat = 180


    let contentWidth =
        elements.reduce(
            CGFloat(0)
        ) {
            current,
            element in

            current +
            (
                element.isWide
                ? wideWidth
                : narrowWidth
            )
        }


    let imageWidth =
        quietZone +
        contentWidth +
        quietZone


    let format =
        UIGraphicsImageRendererFormat()


    // Explicitly keep this at 1 so every barcode module
    // lands on an exact pixel boundary.

    format.scale =
        1


    format.opaque =
        true


    let renderer =
        UIGraphicsImageRenderer(
            size:
                CGSize(
                    width:
                        imageWidth,
                    height:
                        barcodeHeight
                ),
            format:
                format
        )


    return renderer.image {
        context in


        // White background.

        UIColor.white
            .setFill()


        context.fill(
            CGRect(
                x: 0,
                y: 0,
                width:
                    imageWidth,
                height:
                    barcodeHeight
            )
        )


        context.cgContext
            .setShouldAntialias(
                false
            )


        UIColor.black
            .setFill()


        var x =
            quietZone


        for element
            in elements {

            let width =
                element.isWide
                ? wideWidth
                : narrowWidth


            if element.isBar {

                context.fill(
                    CGRect(
                        x:
                            x,
                        y:
                            0,
                        width:
                            width,
                        height:
                            barcodeHeight
                    )
                )
            }


            x +=
                width
        }
    }
}


// MARK: - Code 128 Fallback

private func generateCode128Barcode(
    from string: String
) -> UIImage {

    let context =
        CIContext()


    let filter =
        CIFilter
            .code128BarcodeGenerator()


    filter.message =
        Data(
            string.utf8
        )


    filter.quietSpace =
        10


    if let outputImage =
        filter.outputImage {

        let scaledImage =
            outputImage
                .transformed(
                    by:
                        CGAffineTransform(
                            scaleX: 5,
                            y: 5
                        )
                )


        if let cgImage =
            context.createCGImage(
                scaledImage,
                from:
                    scaledImage.extent
            ) {

            return UIImage(
                cgImage:
                    cgImage
            )
        }
    }


    return UIImage()
}


// MARK: - Shelf Placard OCR

func extractDataFromImage(
    image: UIImage,
    completion:
        @escaping (
            String?,
            Double?
        ) -> Void
) {

    guard
        let cgImage =
            image.cgImage
    else {

        completion(
            nil,
            nil
        )

        return
    }


    let request =
        VNRecognizeTextRequest {
            request,
            error in


            guard
                let observations =
                    request.results
                    as? [
                        VNRecognizedTextObservation
                    ],

                error == nil
            else {

                completion(
                    nil,
                    nil
                )

                return
            }


            let fullText =
                observations
                    .compactMap {
                        $0
                            .topCandidates(1)
                            .first?
                            .string
                    }
                    .joined(
                        separator: " "
                    )


            var foundItem:
                String? = nil


            if let itemRange =
                fullText.range(
                    of:
                        "(?<!\\d)\\d{5,7}(?!\\d)",
                    options:
                        .regularExpression
                ) {

                foundItem =
                    String(
                        fullText[
                            itemRange
                        ]
                    )
            }


            var foundPrice:
                Double? = nil


            do {

                let regex =
                    try NSRegularExpression(
                        pattern:
                            "\\$?\\s*(\\d{1,4})\\s*[\\.,]\\s*(\\d{2})\\b"
                    )


                let nsString =
                    fullText
                    as NSString


                let matches =
                    regex.matches(
                        in:
                            fullText,
                        range:
                            NSRange(
                                location: 0,
                                length:
                                    nsString.length
                            )
                    )


                let prices =
                    matches.compactMap {
                        match
                        -> Double? in


                        let matchString =
                            nsString
                                .substring(
                                    with:
                                        match.range
                                )
                                .replacingOccurrences(
                                    of: "$",
                                    with: ""
                                )
                                .trimmingCharacters(
                                    in:
                                        .whitespaces
                                )


                        return Double(
                            matchString
                        )
                    }


                foundPrice =
                    prices.last


            } catch {}


            completion(
                foundItem,
                foundPrice
            )
        }


    request.recognitionLevel =
        .accurate


    request.usesLanguageCorrection =
        false


    let handler =
        VNImageRequestHandler(
            cgImage:
                cgImage,
            options:
                [:]
        )


    DispatchQueue
        .global(
            qos:
                .userInitiated
        )
        .async {

            try?
                handler.perform(
                    [
                        request
                    ]
                )
        }
}
