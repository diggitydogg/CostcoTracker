import SwiftUI
import SQLite3

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

// A product found in your existing receipt database.
struct ReturnProduct: Identifiable, Hashable {
    let itemNumber: String
    let description: String
    let purchaseCount: Int
    let highestUnitPrice: Double

    var id: String { itemNumber }
}

// One actual purchase line, linked to its receipt.
struct ReturnPurchase: Identifiable {
    let id: Int64
    let itemNumber: String
    let description: String
    let unitPrice: Double
    let quantity: Double
    let receiptBarcode: String
    let date: String
    let warehouse: String

    var lineTotal: Double { unitPrice * quantity }
    var isOnlineOrder: Bool { warehouse.hasPrefix("Online Order") }
    var hasWarehouseReceiptBarcode: Bool {
        !isOnlineOrder && !receiptBarcode.isEmpty && !receiptBarcode.hasPrefix("WHSE_")
    }
}

// Add read-only Return Finder searches to the DBManager you already have.
// No table changes, no re-import, and no changes to your price-match query.
extension DBManager {

    private func returnText(_ statement: OpaquePointer?, at column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func bindReturnText(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        value.withCString { pointer in
            _ = sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
    }

    func findReturnProducts(matching search: String) -> [ReturnProduct] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        let sql = """
            SELECT i.item_number, MIN(i.description),
                   COUNT(DISTINCT i.receipt_barcode), MAX(i.unit_price)
            FROM items i
            WHERE i.unit_price > 0
              AND (i.description LIKE ? COLLATE NOCASE OR i.item_number LIKE ?)
            GROUP BY i.item_number
            ORDER BY COUNT(DISTINCT i.receipt_barcode) DESC, i.item_number
            LIMIT 80;
            """
        var statement: OpaquePointer?
        var products: [ReturnProduct] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("RETURN_FINDER: Product query failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }

        let pattern = "%\(term)%"
        bindReturnText(pattern, to: statement, at: 1)
        bindReturnText(pattern, to: statement, at: 2)

        while sqlite3_step(statement) == SQLITE_ROW {
            products.append(ReturnProduct(
                itemNumber: returnText(statement, at: 0),
                description: returnText(statement, at: 1),
                purchaseCount: Int(sqlite3_column_int(statement, 2)),
                highestUnitPrice: sqlite3_column_double(statement, 3)
            ))
        }
        return products
    }

    func findReturnPurchases(itemNumber: String) -> [ReturnPurchase] {
        let sql = """
            SELECT i.id, i.item_number, i.description, i.unit_price, i.quantity,
                   r.barcode, r.date, r.warehouse
            FROM items i
            JOIN receipts r ON r.barcode = i.receipt_barcode
            WHERE i.item_number = ? AND i.unit_price > 0
            ORDER BY r.date DESC, i.id DESC;
            """
        var statement: OpaquePointer?
        var purchases: [ReturnPurchase] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            print("RETURN_FINDER: Purchase query failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }
        bindReturnText(itemNumber, to: statement, at: 1)

        while sqlite3_step(statement) == SQLITE_ROW {
            purchases.append(ReturnPurchase(
                id: sqlite3_column_int64(statement, 0),
                itemNumber: returnText(statement, at: 1),
                description: returnText(statement, at: 2),
                unitPrice: sqlite3_column_double(statement, 3),
                quantity: sqlite3_column_double(statement, 4),
                receiptBarcode: returnText(statement, at: 5),
                date: returnText(statement, at: 6),
                warehouse: returnText(statement, at: 7)
            ))
        }
        return purchases
    }
}

struct ReturnFinderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searched = false
    @State private var products: [ReturnProduct] = []

    // Only Return Finder uses these camera states. The existing shelf-price
    // camera in ContentView is unchanged.
    @State private var showCamera = false
    @State private var cameraUnavailable = false
    @State private var isRecognizing = false
    @State private var scanResult: ReturnPhotoScan? = nil
    @State private var scanMessage: String? = nil
    @State private var resultsFromPhoto = false

    // Keep the product photo in memory while Return Finder is open.
    // If the user saves a receipt to the Returns tab, SavedReturnStore
    // copies this image into the app's local storage.
    @State private var capturedProductImage: UIImage? = nil

    // State-driven navigation so a result card is ordinary content
    // (not a Button/NavigationLink label). This lets the item-number
    // Text's native .textSelection(.enabled) own a touch-and-hold,
    // and lets the enclosing ScrollView's drag recognition cancel
    // navigation when a touch turns into a scroll.
    @State private var selectedProduct: ReturnProduct? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Photograph a product label, brand, model, or package name. Return Finder suggests matches from your stored receipt descriptions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            cameraUnavailable = true
                            return
                        }
                        showCamera = true
                    } label: {
                        Label(
                            isRecognizing ? "Reading package…" : "Photograph Product",
                            systemImage: "camera.fill"
                        )
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isRecognizing)
                    .sheet(isPresented: $showCamera) {
                        CameraPicker(isPresented: $showCamera) { image in
                            recognizePhoto(image)
                        }
                    }
                    .alert("Camera Unavailable", isPresented: $cameraUnavailable) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text("A device camera is required. You can still search by name below.")
                    }

                    if isRecognizing {
                        ProgressView("Recognizing product text and barcode…")
                    }

                    if let scanMessage {
                        Text(scanMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let scanResult {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Photo recognition")
                                .font(.headline)

                            if !scanResult.searchTerms.isEmpty {
                                Text("Search words: " + scanResult.searchTerms.joined(separator: ", "))
                                    .font(.subheadline)
                            }

                            if !scanResult.packageBarcodes.isEmpty {
                                Text("Package barcode(s): " + scanResult.packageBarcodes.joined(separator: ", "))
                                    .font(.footnote.monospaced())
                                Text("A UPC/EAN on the package is not necessarily Costco's item number. It is not used as a receipt ID.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !scanResult.recognizedLines.isEmpty {
                                DisclosureGroup("Show text read from package") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(scanResult.recognizedLines.indices, id: \.self) { index in
                                            Text(scanResult.recognizedLines[index]).font(.footnote)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Text("Or search by product name / Costco item number")
                        .font(.subheadline.bold())

                    TextField("Try GLOVE, TISSUE, or an item #", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(searchProducts)

                    Button(action: searchProducts) {
                        Label("Search Purchase History", systemImage: "magnifyingglass")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if searched && products.isEmpty {
                        Text("No matching products found. Try one shorter word from the package, or photograph the product name/model more closely.")
                            .foregroundStyle(.secondary)
                    }

                    if !products.isEmpty {
                        Text(
                            resultsFromPhoto
                                ? "Suggested receipt matches (\(products.count))"
                                : "\(products.count) matching product\(products.count == 1 ? "" : "s")"
                        )
                        .font(.headline)

                        if resultsFromPhoto {
                            Text("Confirm the product, model, and package size before selecting a purchase. Suggestions are based on receipt text, not a verified UPC-to-item-number link.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(products) { product in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(product.description.isEmpty ? "Item \(product.itemNumber)" : product.description)
                                        .font(.headline)
                                    HStack(spacing: 4) {
                                        Text("Item #\(product.itemNumber)")
                                            .textSelection(.enabled)
                                        Text("• \(product.purchaseCount) receipt\(product.purchaseCount == 1 ? "" : "s")")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(String(format: "$%.2f", product.highestUnitPrice))
                                        .fontWeight(.bold)
                                    Text("highest paid/unit")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedProduct = product
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Return Finder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $selectedProduct) { product in
                ReturnPurchaseHistoryView(
                    product: product,
                    productImage: resultsFromPhoto ? capturedProductImage : nil
                )
            }
        }
    }

    private func searchProducts() {
        scanResult = nil
        scanMessage = nil
        resultsFromPhoto = false
        products = DBManager.shared.findReturnProducts(matching: searchText)
        searched = true
    }

    private func recognizePhoto(_ image: UIImage) {
        // Clear stale suggestions so an unsuccessful photo can never display
        // unrelated results from the previous product.
        isRecognizing = true
        searched = false
        products = []
        scanResult = nil
        scanMessage = nil
        resultsFromPhoto = true
        capturedProductImage = image

        ReturnPhotoScanner.scan(image: image) { result in
            isRecognizing = false
            switch result {
            case .failure(let error):
                scanMessage = "Could not read photo: " + error.localizedDescription
                searched = true
            case .success(let scan):
                scanResult = scan
                guard !scan.searchTerms.isEmpty else {
                    scanMessage = scan.packageBarcodes.isEmpty
                        ? "No useful product words detected. Try photographing the printed product name or model."
                        : "Barcode detected, but no product words. Photograph the name/label as well; Costco item numbers and package UPCs are different identifiers."
                    searched = true
                    return
                }

                products = suggestedProducts(for: scan.searchTerms)
                searched = true
                if products.isEmpty {
                    scanMessage = "No receipt descriptions matched the recognized words. You can edit a word below and search manually."
                }
            }
        }
    }

    // Rank products by how many distinct words from the packaging appear
    // in their receipt descriptions. This is a suggestion, not identity proof.
    private func suggestedProducts(for terms: [String]) -> [ReturnProduct] {
        var byItem: [String: (product: ReturnProduct, score: Int, hits: Int)] = [:]
        for term in terms.prefix(12) {
            let weight = term.count >= 6 ? 3 : 1
            for product in DBManager.shared.findReturnProducts(matching: term) {
                let old = byItem[product.itemNumber]
                byItem[product.itemNumber] = (
                    product: product,
                    score: (old?.score ?? 0) + weight,
                    hits: (old?.hits ?? 0) + 1
                )
            }
        }
        return byItem.values.sorted { a, b in
            if a.hits != b.hits { return a.hits > b.hits }
            if a.score != b.score { return a.score > b.score }
            if a.product.purchaseCount != b.product.purchaseCount {
                return a.product.purchaseCount > b.product.purchaseCount
            }
            return a.product.itemNumber < b.product.itemNumber
        }.prefix(30).map(\.product)
    }
}

private enum ReturnSort: String, CaseIterable, Identifiable {
    case highestPaid = "Highest paid first"
    case newest = "Newest first"
    case oldest = "Oldest first"
    var id: Self { self }
}

private struct ReturnPurchaseHistoryView: View {
    let product: ReturnProduct
    let productImage: UIImage?

    @StateObject private var returnStore = SavedReturnStore.shared
    @State private var purchases: [ReturnPurchase] = []
    @State private var sort: ReturnSort = .highestPaid
    @State private var savingPurchaseID: Int64? = nil
    @State private var saveMessages: [Int64: String] = [:]

    private var sortedPurchases: [ReturnPurchase] {
        purchases.sorted { a, b in
            switch sort {
            case .highestPaid:
                if a.unitPrice != b.unitPrice { return a.unitPrice > b.unitPrice }
                return a.date > b.date
            case .newest:
                if a.date != b.date { return a.date > b.date }
                return a.unitPrice > b.unitPrice
            case .oldest:
                if a.date != b.date { return a.date < b.date }
                return a.unitPrice > b.unitPrice
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if let productImage {
                    Image(uiImage: productImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Text(product.description)
                    .font(.title3.bold())
                Text("Costco item #\(product.itemNumber)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Every stored purchase of this item is shown separately. Match the receipt to the purchase you are actually returning; a stored receipt does not establish return eligibility.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Sort receipts", selection: $sort) {
                    ForEach(ReturnSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)

                ForEach(sortedPurchases) { purchase in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(String(format: "$%.2f", purchase.unitPrice))
                                .font(.title2.bold())
                            Text("per unit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if purchase.unitPrice == product.highestUnitPrice {
                                Text("Highest recorded price")
                                    .font(.caption2.bold())
                                    .padding(6)
                                    .background(Color.green.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        Text("Purchased: \(formattedReturnDate(purchase.date))")
                        Text("Warehouse: \(purchase.warehouse)")
                        Text("Quantity: \(purchase.quantity, specifier: "%g")")
                        Text(String(format: "Line total: $%.2f", purchase.lineTotal))

                        if purchase.hasWarehouseReceiptBarcode {
                            Divider()
                            Image(uiImage: generateBarcode(from: purchase.receiptBarcode))
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(height: 90)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.white)
                            Text(purchase.receiptBarcode)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity)
                            Text("Generated from the stored receipt identifier. Confirm it scans at Costco.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if purchase.isOnlineOrder {
                            Text("Online order ID: \(purchase.receiptBarcode). Use the original online order details for returns.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No original scannable receipt barcode was stored for this purchase.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }

                        Button {
                            saveReturn(purchase)
                        } label: {
                            Label(
                                isSaved(purchase) ? "Saved to Returns" : "Save This Return",
                                systemImage: isSaved(purchase)
                                    ? "checkmark.circle.fill"
                                    : "tray.and.arrow.down.fill"
                            )
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(isSaved(purchase))

                        Button {
                            saveReceiptCard(purchase)
                        } label: {
                            Label(
                                savingPurchaseID == purchase.id ? "Saving…" : "Save Receipt to Photos",
                                systemImage: "square.and.arrow.down"
                            )
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(savingPurchaseID != nil)

                        if let message = saveMessages[purchase.id] {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(message.hasPrefix("Saved") ? .green : .red)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Purchase History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            purchases = DBManager.shared.findReturnPurchases(itemNumber: product.itemNumber)
        }
    }

    private func isSaved(_ purchase: ReturnPurchase) -> Bool {
        returnStore.items.contains {
            $0.itemNumber == purchase.itemNumber &&
            $0.barcode == purchase.receiptBarcode
        }
    }

    private func saveReturn(_ purchase: ReturnPurchase) {
        let match = ReceiptMatch(
            itemNumber: purchase.itemNumber,
            description: purchase.description,
            unitPrice: purchase.unitPrice,
            quantity: purchase.quantity,
            barcode: purchase.receiptBarcode,
            date: purchase.date,
            warehouse: purchase.warehouse,
            withinWindow: false,
            qualifies: false,
            savings: 0
        )

        returnStore.add(
            match: match,
            image: productImage
        )
    }

    private func saveReceiptCard(_ purchase: ReturnPurchase) {
        savingPurchaseID = purchase.id
        saveMessages[purchase.id] = nil
        ReturnReceiptCardSaver.save(purchase: purchase) { success in
            savingPurchaseID = nil
            saveMessages[purchase.id] = success
                ? "Saved to Costco Returns album!"
                : "Save failed. Check Photos permission in Settings."
        }
    }
}
