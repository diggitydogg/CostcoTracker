import SwiftUI
import UIKit

// Display-only formatting for purchase dates stored as "yyyy-MM-dd".
// Falls back to the original string if it cannot be parsed.
private func formattedReturnDate(_ value: String) -> String {

    let input = DateFormatter()
    input.locale = Locale(identifier: "en_US_POSIX")
    input.dateFormat = "yyyy-MM-dd"

    guard let date = input.date(from: String(value.prefix(10))) else {
        return value
    }

    return date.formatted(
        .dateTime
            .month(.abbreviated)
            .day()
            .year()
    )
}

struct SavedReturnsView: View {

    @StateObject private var returnStore = SavedReturnStore.shared
    @State private var showFinder = false
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if returnStore.items.isEmpty {
                    emptyView
                } else {
                    savedReturnsList
                }
            }
            .navigationTitle("Returns")
            .sheet(isPresented: $showFinder) {
                ReturnFinderView()
            }
        }
        .confirmationDialog(
            "Clear all saved returns?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {

            Button("Clear All", role: .destructive) {
                returnStore.clear()
            }

            Button("Cancel", role: .cancel) { }

        } message: {
            Text(
                "This removes every saved return and its locally stored product photo from the app."
            )
        }
    }

    // MARK: - Empty Screen

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 65))
                .foregroundColor(.secondary)

            Text("No Returns Saved")
                .font(.title2.bold())

            Text(
                "Photograph a product and select the purchase receipt you want to keep for a future return."
            )
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)
            .padding(.horizontal, 30)

            Button {
                showFinder = true
            } label: {
                Label(
                    "Find a Return",
                    systemImage: "camera.fill"
                )
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }

    // MARK: - Compact Saved Returns List

    private var savedReturnsList: some View {
        List {
            Section {
                Button {
                    showFinder = true
                } label: {
                    Label(
                        "Find Another Return",
                        systemImage: "camera.fill"
                    )
                    .fontWeight(.semibold)
                }
            }

            Section {
                ForEach(returnStore.items) { item in
                    NavigationLink {
                        SavedReturnDetailView(item: item)
                    } label: {
                        SavedReturnRowView(
                            item: item,
                            image: returnStore.image(for: item)
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            returnStore.remove(item)
                        } label: {
                            Label(
                                "Delete",
                                systemImage: "trash"
                            )
                        }
                        .tint(.red)
                    }
                }
            } header: {
                Text(
                    "\(returnStore.items.count) Saved Return\(returnStore.items.count == 1 ? "" : "s")"
                )
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label(
                        "Clear All Returns",
                        systemImage: "trash"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}


// MARK: - Compact Row

private struct SavedReturnRowView: View {

    let item: SavedReturnItem
    let image: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.12)

                        Image(systemName: "shippingbox")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 12
                )
            )

            VStack(
                alignment: .leading,
                spacing: 5
            ) {
                Text(
                    item.description.isEmpty
                    ? "Item \(item.itemNumber)"
                    : item.description
                )
                .font(.headline)
                .lineLimit(2)

                Text(
                    "Item #\(item.itemNumber)"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)

                HStack {
                    Text(
                        item.unitPrice,
                        format: .currency(
                            code: "USD"
                        )
                    )
                    .fontWeight(.semibold)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(formattedReturnDate(item.date))
                        .foregroundColor(.secondary)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Return Detail Screen

private struct SavedReturnDetailView: View {

    let item: SavedReturnItem

    @StateObject private var returnStore =
        SavedReturnStore.shared

    @State private var showPhoto = false
    @State private var showBarcode = false

    @State private var isSavingReceiptCard = false
    @State private var receiptCardSaveMessage: String? = nil

    private var productImage: UIImage? {
        returnStore.image(for: item)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {

                // Product photo

                if let productImage {
                    Button {
                        showPhoto = true
                    } label: {
                        Image(uiImage: productImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 340)
                            .background(
                                Color.black.opacity(0.03)
                            )
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 16
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Product information

                VStack(
                    alignment: .leading,
                    spacing: 10
                ) {
                    Text(
                        item.description.isEmpty
                        ? "Item \(item.itemNumber)"
                        : item.description
                    )
                    .font(.title2.bold())

                    Text(
                        "Costco item #\(item.itemNumber)"
                    )
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                    Divider()

                    detailRow(
                        title: "Price paid",
                        value:
                            item.unitPrice.formatted(
                                .currency(
                                    code: "USD"
                                )
                            )
                    )

                    detailRow(
                        title: "Quantity",
                        value:
                            String(
                                format: "%g",
                                item.quantity
                            )
                    )

                    detailRow(
                        title: "Purchase date",
                        value: formattedReturnDate(item.date)
                    )

                    detailRow(
                        title: "Warehouse",
                        value: item.warehouse
                    )
                }
                .padding()
                .background(
                    Color(
                        .secondarySystemGroupedBackground
                    )
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 16
                    )
                )

                // Receipt barcode

                if item.hasWarehouseReceiptBarcode {

                    Button {
                        showBarcode = true
                    } label: {
                        VStack(spacing: 10) {
                            Text("Receipt Barcode")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Image(
                                uiImage:
                                    generateBarcode(
                                        from:
                                            item.barcode
                                    )
                            )
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(height: 95)
                            .frame(
                                maxWidth: .infinity
                            )
                            .padding(.horizontal)

                            Text(item.barcode)
                                .font(
                                    .caption.monospaced()
                                )
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .padding()
                        .frame(
                            maxWidth: .infinity
                        )
                        .background(Color.white)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 16
                            )
                        )
                    }
                    .buttonStyle(.plain)

                } else if item.isOnlineOrder {

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
                        Text("Online Order")
                            .font(.headline)

                        Text(
                            "Order ID: \(item.barcode)"
                        )
                        .font(
                            .subheadline.monospaced()
                        )

                        Text(
                            "Use the original Costco.com order details for this return."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        Color(
                            .secondarySystemGroupedBackground
                        )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 16
                        )
                    )

                } else {

                    Text(
                        "Original receipt barcode not available"
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        Color(
                            .secondarySystemGroupedBackground
                        )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 16
                        )
                    )
                }

                // Save Receipt to Photos

                Button {
                    saveReceiptCard()
                } label: {
                    Label(
                        isSavingReceiptCard
                            ? "Saving…"
                            : "Save Receipt to Photos",
                        systemImage: "square.and.arrow.down"
                    )
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isSavingReceiptCard)

                if let receiptCardSaveMessage {
                    Text(receiptCardSaveMessage)
                        .font(.footnote)
                        .foregroundColor(
                            receiptCardSaveMessage.hasPrefix("Saved")
                                ? .green
                                : .red
                        )
                }
            }
            .padding()
        }
        .background(
            Color(.systemGroupedBackground)
        )
        .navigationTitle("Saved Return")
        .navigationBarTitleDisplayMode(.inline)

        .fullScreenCover(
            isPresented: $showPhoto
        ) {
            if let productImage {
                ZoomableProductPhotoView(
                    image: productImage
                )
            }
        }

        .fullScreenCover(
            isPresented: $showBarcode
        ) {
            ExpandedReceiptBarcodeView(
                receiptIdentifier: item.barcode
            )
        }
    }

    private func saveReceiptCard() {

        isSavingReceiptCard = true
        receiptCardSaveMessage = nil

        ReturnReceiptCardSaver.save(
            purchase: item.asReturnPurchase
        ) { success in

            isSavingReceiptCard = false

            receiptCardSaveMessage = success
                ? "Saved to Costco Returns album!"
                : "Save failed. Check Photos permission in Settings."
        }
    }

    private func detailRow(
        title: String,
        value: String
    ) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(
                    .trailing
                )
        }
    }
}


// MARK: - Full-Screen Product Photo

private struct ZoomableProductPhotoView: View {

    let image: UIImage

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            NativeZoomableImageView(
                image: image
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(
                            systemName: "xmark"
                        )
                        .font(.headline.bold())
                        .foregroundColor(.white)
                        .frame(
                            width: 44,
                            height: 44
                        )
                        .background(
                            Color.black.opacity(0.65)
                        )
                        .clipShape(Circle())
                    }
                }
                .padding()

                Spacer()
            }
        }
    }
}


// MARK: - Native iPhone-Style Zooming

private struct NativeZoomableImageView:
    UIViewRepresentable {

    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(
        context: Context
    ) -> UIScrollView {

        let scrollView = UIScrollView()

        scrollView.delegate =
            context.coordinator

        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0

        scrollView.bounces = true
        scrollView.bouncesZoom = true

        scrollView
            .showsHorizontalScrollIndicator =
                false

        scrollView
            .showsVerticalScrollIndicator =
                false

        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .black

        let imageView =
            UIImageView(image: image)

        imageView.contentMode =
            .scaleAspectFit

        imageView
            .translatesAutoresizingMaskIntoConstraints =
                false

        imageView.isUserInteractionEnabled =
            true

        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([

            imageView.leadingAnchor.constraint(
                equalTo:
                    scrollView
                        .contentLayoutGuide
                        .leadingAnchor
            ),

            imageView.trailingAnchor.constraint(
                equalTo:
                    scrollView
                        .contentLayoutGuide
                        .trailingAnchor
            ),

            imageView.topAnchor.constraint(
                equalTo:
                    scrollView
                        .contentLayoutGuide
                        .topAnchor
            ),

            imageView.bottomAnchor.constraint(
                equalTo:
                    scrollView
                        .contentLayoutGuide
                        .bottomAnchor
            ),

            imageView.widthAnchor.constraint(
                equalTo:
                    scrollView
                        .frameLayoutGuide
                        .widthAnchor
            ),

            imageView.heightAnchor.constraint(
                equalTo:
                    scrollView
                        .frameLayoutGuide
                        .heightAnchor
            )
        ])

        context.coordinator.imageView =
            imageView

        context.coordinator.scrollView =
            scrollView

        let doubleTap =
            UITapGestureRecognizer(
                target:
                    context.coordinator,
                action:
                    #selector(
                        Coordinator
                            .handleDoubleTap(_:)
                    )
            )

        doubleTap.numberOfTapsRequired = 2

        scrollView.addGestureRecognizer(
            doubleTap
        )

        return scrollView
    }

    func updateUIView(
        _ scrollView: UIScrollView,
        context: Context
    ) {

        context.coordinator
            .imageView?
            .image = image
    }


    final class Coordinator:
        NSObject,
        UIScrollViewDelegate {

        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(
            in scrollView: UIScrollView
        ) -> UIView? {

            imageView
        }

        @objc
        func handleDoubleTap(
            _ recognizer:
                UITapGestureRecognizer
        ) {

            guard
                let scrollView,
                let imageView
            else {
                return
            }

            // Double tap again to return
            // to normal size.

            if scrollView.zoomScale >
                scrollView.minimumZoomScale +
                0.01 {

                scrollView.setZoomScale(
                    scrollView.minimumZoomScale,
                    animated: true
                )

                return
            }

            // Zoom toward the location
            // the user actually tapped.

            let targetScale =
                min(
                    2.5,
                    scrollView.maximumZoomScale
                )

            let tapPoint =
                recognizer.location(
                    in: imageView
                )

            let width =
                scrollView.bounds.width /
                targetScale

            let height =
                scrollView.bounds.height /
                targetScale

            let zoomRect =
                CGRect(
                    x:
                        tapPoint.x -
                        width / 2,

                    y:
                        tapPoint.y -
                        height / 2,

                    width: width,
                    height: height
                )

            scrollView.zoom(
                to: zoomRect,
                animated: true
            )
        }
    }
}


