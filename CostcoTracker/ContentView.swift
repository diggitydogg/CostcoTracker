import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {

    @State private var selectedItem: PhotosPickerItem? = nil

    @State private var itemNumber: String = ""
    @State private var shelfPrice: String = ""

    @State private var isProcessing = false
    @State private var showSyncBrowser = false
    @State private var showBackupRestore = false
    @State private var matches: [ReceiptMatch] = []
    @State private var priceAdjustments: [PriceAdjustmentRecord] = []

    @State private var showCamera = false
    @State private var cameraUnavailable = false

    @State private var dbCount = 0
    @State private var searchPerformed = false
    @State private var isCheckingPrice = false

    // Direct "View Purchase History" access from the manual entry
    // form, independent of Check Price / shelf price.
    @State private var directHistoryItemNumber = ""
    @State private var showDirectPurchaseHistory = false

    @StateObject private var priceQueue =
        PriceMatchQueue.shared

    @AppStorage("costco_last_successful_sync")
    private var lastSuccessfulSyncTimestamp: Double = 0
    
    private enum PriceEntryField: Hashable {
        case itemNumber
        case shelfPrice
    }

    @FocusState private var focusedField: PriceEntryField?


    // MARK: - Last Successful Sync

    private var lastSyncDate: Date? {

        guard lastSuccessfulSyncTimestamp > 0 else {
            return nil
        }

        return Date(
            timeIntervalSince1970:
                lastSuccessfulSyncTimestamp
        )
    }


    private var lastSyncRelativeText: String {

        guard let lastSyncDate else {
            return "Last sync not recorded yet"
        }

        let formatter =
            RelativeDateTimeFormatter()

        formatter.unitsStyle = .full

        return "Last synced " +
            formatter.localizedString(
                for: lastSyncDate,
                relativeTo: Date()
            )
    }


    private var lastSyncExactText: String? {

        guard let lastSyncDate else {
            return nil
        }

        return lastSyncDate.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }


    // MARK: - Main View

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(spacing: 20) {

                    // MARK: Data (Backup & Restore)

                    HStack {
                        Spacer()

                        Button {
                            showBackupRestore = true
                        } label: {
                            Label("Data", systemImage: "gearshape")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // MARK: Receipt Sync

                    VStack(spacing: 6) {

                        Button {

                            showSyncBrowser = true

                        } label: {

                            HStack {

                                Image(
                                    systemName:
                                        "arrow.triangle.2.circlepath"
                                )

                                Text(
                                    "Sync Latest Costco Purchases"
                                )
                            }
                            .font(.subheadline)
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(
                                Color.blue.opacity(0.12)
                            )
                            .foregroundColor(.blue)
                            .cornerRadius(10)
                        }


                        Text(
                            "\(dbCount) receipts synced"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)


                        HStack(spacing: 4) {

                            Image(
                                systemName: "clock"
                            )
                            .font(.caption2)

                            Text(lastSyncRelativeText)
                                .font(.caption)

                            if let exact =
                                lastSyncExactText {

                                Text("•")
                                    .font(.caption)

                                Text(exact)
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }


                    // MARK: Scanner Card

                    VStack(spacing: 18) {

                        // Camera

                        Button {

                            if UIImagePickerController
                                .isSourceTypeAvailable(
                                    .camera
                                ) {

                                showCamera = true

                            } else {

                                cameraUnavailable = true
                            }

                        } label: {

                            Label(
                                "Scan Shelf Price",
                                systemImage: "camera.fill"
                            )
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .sheet(
                            isPresented: $showCamera
                        ) {

                            CameraPicker(
                                isPresented: $showCamera
                            ) { image in

                                processCameraPhoto(
                                    image
                                )
                            }
                        }
                        .alert(
                            "Camera Unavailable",
                            isPresented:
                                $cameraUnavailable
                        ) {

                            Button(
                                "OK",
                                role: .cancel
                            ) { }

                        } message: {

                            Text(
                                "Please use an iPhone with an available camera."
                            )
                        }


                        // Photo Library

                        PhotosPicker(
                            selection: $selectedItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {

                            HStack {

                                Image(
                                    systemName:
                                        "camera.viewfinder"
                                )

                                Text(
                                    isProcessing
                                    ? "Scanning Placard..."
                                    : "Select Photo from Library"
                                )
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .onChange(
                            of: selectedItem
                        ) {

                            processPhoto()
                        }


                        // MARK: Item Details

                        VStack(
                            alignment: .leading,
                            spacing: 10
                        ) {

                            Text("Item Details")
                                .font(
                                    .subheadline.bold()
                                )
                                .foregroundStyle(
                                    .secondary
                                )


                            HStack(spacing: 12) {

                                // Costco Item Number

                                VStack(
                                    alignment: .leading,
                                    spacing: 5
                                ) {

                                    Label(
                                        "Item Number",
                                        systemImage:
                                            "number"
                                    )
                                    .font(.caption.bold())
                                    .foregroundStyle(
                                        .secondary
                                    )


                                    HStack(spacing: 8) {

                                        TextField(
                                            "1234567",
                                            text: $itemNumber
                                        )
                                        .keyboardType(
                                            .numberPad
                                        )
                                        .focused(
                                            $focusedField,
                                            equals: .itemNumber
                                        )

                                        if !itemNumber.isEmpty {

                                            Button {

                                                itemNumber = ""
                                                matches = []
                                                priceAdjustments = []
                                                searchPerformed = false
                                                focusedField = .itemNumber

                                            } label: {

                                                Image(
                                                    systemName:
                                                        "xmark.circle.fill"
                                                )
                                                .foregroundStyle(
                                                    .secondary
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(
                                                "Clear item number"
                                            )
                                        }
                                    }
                                    .padding(
                                        .horizontal,
                                        12
                                    )
                                    .frame(height: 48)
                                    .background(
                                        Color(
                                            .secondarySystemGroupedBackground
                                        )
                                    )
                                    .overlay {

                                        RoundedRectangle(
                                            cornerRadius: 10
                                        )
                                        .stroke(
                                            Color.secondary
                                                .opacity(
                                                    0.35
                                                ),
                                            lineWidth: 1
                                        )
                                    }
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 10
                                        )
                                    )
                                }


                                // Current Costco Shelf Price

                                VStack(
                                    alignment: .leading,
                                    spacing: 5
                                ) {

                                    Label(
                                        "Shelf Price",
                                        systemImage:
                                            "dollarsign"
                                    )
                                    .font(.caption.bold())
                                    .foregroundStyle(
                                        .secondary
                                    )


                                    HStack(spacing: 8) {

                                        Text("$")
                                            .foregroundStyle(
                                                .secondary
                                            )

                                        TextField(
                                            "0.00",
                                            text:
                                                $shelfPrice
                                        )
                                        .keyboardType(
                                            .decimalPad
                                        )
                                        .focused(
                                            $focusedField,
                                            equals: .shelfPrice
                                        )

                                        if !shelfPrice.isEmpty {

                                            Button {

                                                shelfPrice = ""
                                                matches = []
                                                priceAdjustments = []
                                                searchPerformed = false
                                                focusedField = .shelfPrice

                                            } label: {

                                                Image(
                                                    systemName:
                                                        "xmark.circle.fill"
                                                )
                                                .foregroundStyle(
                                                    .secondary
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(
                                                "Clear shelf price"
                                            )
                                        }
                                    }
                                    .padding(
                                        .horizontal,
                                        12
                                    )
                                    .frame(height: 48)
                                    .background(
                                        Color(
                                            .secondarySystemGroupedBackground
                                        )
                                    )
                                    .overlay {

                                        RoundedRectangle(
                                            cornerRadius: 10
                                        )
                                        .stroke(
                                            Color.secondary
                                                .opacity(
                                                    0.35
                                                ),
                                            lineWidth: 1
                                        )
                                    }
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 10
                                        )
                                    )
                                }
                            }
                        }
                        .padding(.top, 2)


                        // MARK: Check Price

                        Button {

                            guard !isCheckingPrice else {
                                return
                            }

                            // Dismiss the keyboard immediately.
                            focusedField = nil

                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil,
                                from: nil,
                                for: nil
                            )

                            // Immediate tactile confirmation that the tap registered.
                            UIImpactFeedbackGenerator(style: .light)
                                .impactOccurred()

                            // Immediately change the UI so the user knows
                            // the search is underway.
                            isCheckingPrice = true

                            // Remove any result from the previous search.
                            matches = []
                            searchPerformed = false

                            // Give SwiftUI a moment to display the progress state
                            // before the database lookup begins.
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.08
                            ) {

                                runSearch()

                                isCheckingPrice = false
                            }

                        } label: {

                            HStack(
                                spacing: 10
                            ) {

                                if isCheckingPrice {

                                    ProgressView()
                                        .tint(.white)

                                    Text("Checking Price…")

                                } else {

                                    Text("Check Price")
                                }
                            }
                            .font(.headline)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isCheckingPrice)
                        .opacity(
                            isCheckingPrice
                            ? 0.85
                            : 1
                        )
                        .disabled(
                            itemNumber
                                .trimmingCharacters(
                                    in:
                                        .whitespacesAndNewlines
                                )
                                .isEmpty ||
                            Double(shelfPrice) == nil
                        )
                        .opacity(
                            itemNumber
                                .trimmingCharacters(
                                    in:
                                        .whitespacesAndNewlines
                                )
                                .isEmpty ||
                            Double(shelfPrice) == nil
                            ? 0.55
                            : 1
                        )


                        // MARK: View Purchase History (direct, item-number only)

                        Button {

                            let trimmedItemNumber =
                                itemNumber.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )

                            guard !trimmedItemNumber.isEmpty else {
                                return
                            }

                            focusedField = nil

                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil,
                                from: nil,
                                for: nil
                            )

                            directHistoryItemNumber = trimmedItemNumber
                            showDirectPurchaseHistory = true

                        } label: {

                            Label(
                                "View Purchase History",
                                systemImage: "chart.bar.doc.horizontal"
                            )
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .disabled(
                            itemNumber
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                .isEmpty
                        )
                        .opacity(
                            itemNumber
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                .isEmpty
                            ? 0.55
                            : 1
                        )
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
                    .shadow(radius: 2)


                    // MARK: No Result

                    if searchPerformed &&
                        matches.isEmpty {

                        Text(
                            "No matching receipt found for item \(itemNumber)."
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                    }


                    // MARK: Add Results to Queue

                    if !matches.isEmpty {

                        Button {

                            guard let price =
                                    Double(
                                        shelfPrice
                                    )
                            else {
                                return
                            }

                            priceQueue.add(
                                matches: matches,
                                newPrice: price
                            )

                        } label: {

                            Label(
                                "Add Matches to Price Matches",
                                systemImage:
                                    "plus.circle.fill"
                            )
                            .fontWeight(.bold)
                            .frame(
                                maxWidth: .infinity
                            )
                            .padding(16)
                            .background(
                                Color.blue
                            )
                            .foregroundColor(
                                .white
                            )
                            .cornerRadius(12)
                        }
                    }


                    // MARK: Current Search Results

                    ForEach(matches) { match in

                        ResultCardView(
                            match: match,
                            priceAdjustments: priceAdjustments,
                            newPrice:
                                Double(
                                    shelfPrice
                                ) ?? 0
                        )
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(
                Color(
                    UIColor
                        .systemGroupedBackground
                )
            )
            .background {

                KeyboardDismissTapCatcher {

                    focusedField = nil
                }
            }
            .navigationBarHidden(true)

            .navigationDestination(
                isPresented: $showDirectPurchaseHistory
            ) {

                ItemPurchaseHistoryView(
                    itemNumber: directHistoryItemNumber
                )
            }

            .onAppear {

                dbCount =
                    DBManager.shared
                        .getReceiptCount()
            }

            .sheet(
                isPresented:
                    $showSyncBrowser
            ) {

                CostcoSyncWrapperView(
                    isPresented:
                        $showSyncBrowser
                ) {

                    dbCount =
                        DBManager.shared
                            .getReceiptCount()

                    if !itemNumber.isEmpty,
                       Double(shelfPrice) != nil {

                        runSearch()
                    }
                }
            }

            .sheet(
                isPresented:
                    $showBackupRestore
            ) {

                BackupRestoreView()
            }
        }
    }


    // MARK: - Camera Placard Scan

    private func processCameraPhoto(
        _ image: UIImage
    ) {

        isProcessing = true

        matches = []
        priceAdjustments = []
        searchPerformed = false

        itemNumber = ""
        shelfPrice = ""

        extractDataFromImage(
            image: image
        ) {
            foundItem,
            foundPrice in

            DispatchQueue.main.async {

                if let item = foundItem {

                    self.itemNumber =
                        item
                }

                if let price =
                    foundPrice {

                    self.shelfPrice =
                        String(
                            format:
                                "%.2f",
                            price
                        )
                }

                self.isProcessing =
                    false

                if foundItem != nil &&
                    foundPrice != nil {

                    self.runSearch()
                }
            }
        }
    }


    // MARK: - Photo Library Placard Scan

    private func processPhoto() {

        guard let selectedItem else {
            return
        }

        isProcessing = true

        Task {

            if let data =
                try? await selectedItem
                    .loadTransferable(
                        type: Data.self
                    ),

               let uiImage =
                UIImage(data: data) {

                extractDataFromImage(
                    image: uiImage
                ) {
                    foundItem,
                    foundPrice in

                    DispatchQueue.main.async {

                        if let item =
                            foundItem {

                            self.itemNumber =
                                item
                        }

                        if let price =
                            foundPrice {

                            self.shelfPrice =
                                String(
                                    format:
                                        "%.2f",
                                    price
                                )
                        }

                        self.isProcessing =
                            false

                        if foundItem != nil &&
                            foundPrice != nil {

                            self.runSearch()
                        }
                    }
                }
            }
        }
    }


    // MARK: - Search Receipt Database

    private func runSearch() {

        searchPerformed = false

        let cleanItem =
            itemNumber.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard
            !cleanItem.isEmpty,
            let price =
                Double(shelfPrice)
        else {
            return
        }

        matches =
            DBManager.shared.queryMatch(
                itemNum: cleanItem,
                shelfPrice: price
            )

        priceAdjustments =
            DBManager.shared.priceAdjustments(
                for: cleanItem
            )

        searchPerformed = true
    }
}


// MARK: - Individual Price Match Result

struct ResultCardView: View {

    let match: ReceiptMatch
    let priceAdjustments: [PriceAdjustmentRecord]
    let newPrice: Double

    @State private var isSaving = false
    @State private var saveMessage: String? = nil
    @State private var showExpandedBarcode = false


    private var isOnline: Bool {
        match.warehouse.hasPrefix("Online Order")
    }


    private var statusColor: Color {

        if isOnline {
            return .blue
        }

        if match.qualifies {
            return .green
        }

        if match.savings > 0 {
            return .orange
        }

        return .secondary
    }


    private var statusIcon: String {

        if isOnline {
            return "globe"
        }

        if match.qualifies {
            return "checkmark.circle.fill"
        }

        if match.savings > 0 {
            return "clock.fill"
        }

        return "minus.circle.fill"
    }


    private var statusTitle: String {

        if isOnline {
            return "Online Purchase"
        }

        if match.qualifies {
            return "Price Adjustment Candidate"
        }

        if match.savings > 0 {
            return "Price Drop Found"
        }

        return "No Price Drop"
    }


    private var statusMessage: String {

        if isOnline {
            return "Compare this purchase with Costco.com pricing."
        }

        if match.qualifies {
            return "This purchase is within the 30-day adjustment window."
        }

        if match.savings > 0 {
            return "The price dropped, but this purchase is outside the 30-day adjustment window."
        }

        return "The current price is not lower than what you paid."
    }


    private var currentPriceLabel: String {
        isOnline
            ? "Current Price"
            : "Shelf Price"
    }


    private var sourceName: String {

        if isOnline {
            return "Costco.com"
        }

        return match.warehouse
    }


    private var formattedDate: String {

        let input = DateFormatter()

        input.locale =
            Locale(
                identifier: "en_US_POSIX"
            )

        input.dateFormat =
            "yyyy-MM-dd"


        guard
            let date =
                input.date(
                    from:
                        String(
                            match.date.prefix(10)
                        )
                )
        else {
            return match.date
        }


        let output = DateFormatter()

        output.locale =
            Locale.current

        output.dateFormat =
            "MMM d, yyyy"


        return output.string(
            from: date
        )
    }


    var body: some View {

        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            // MARK: Status

            HStack(
                spacing: 8
            ) {

                Image(
                    systemName:
                        statusIcon
                )


                Text(
                    statusTitle
                )
                .fontWeight(
                    .semibold
                )


                Spacer()
            }
            .font(
                .subheadline
            )
            .foregroundStyle(
                statusColor
            )


            // MARK: Product

            VStack(
                alignment: .leading,
                spacing: 5
            ) {

                Text(
                    match.description
                )
                .font(
                    .title3
                )
                .fontWeight(
                    .bold
                )
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )


                Text(
                    "Item #\(match.itemNumber)"
                )
                .font(
                    .caption
                )
                .foregroundStyle(
                    .secondary
                )
                .textSelection(.enabled)

                NavigationLink {
                    ItemPurchaseHistoryView(
                        itemNumber: match.itemNumber
                    )
                } label: {
                    Label(
                        "View Purchase History",
                        systemImage: "chart.bar.doc.horizontal"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }


            // MARK: Savings

            if match.savings > 0 {

                HStack {

                    VStack(
                        alignment: .leading,
                        spacing: 3
                    ) {

                        Text(
                            "YOU SAVE"
                        )
                        .font(
                            .caption
                        )
                        .fontWeight(
                            .semibold
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        Text(
                            match.savings,
                            format:
                                .currency(
                                    code: "USD"
                                )
                        )
                        .font(
                            .title
                        )
                        .fontWeight(
                            .bold
                        )
                        .foregroundStyle(
                            .green
                        )
                    }


                    Spacer()
                }
                .padding(14)
                .background(
                    Color.green
                        .opacity(0.08)
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12
                    )
                )
            }


            // MARK: Price Comparison

            HStack(
                spacing: 10
            ) {

                priceBox(
                    title:
                        "You Paid",

                    amount:
                        match.unitPrice,

                    color:
                        .primary
                )


                Image(
                    systemName:
                        "arrow.right"
                )
                .font(
                    .subheadline
                )
                .foregroundStyle(
                    .secondary
                )


                priceBox(
                    title:
                        currentPriceLabel,

                    amount:
                        newPrice,

                    color:
                        match.savings > 0
                        ? .green
                        : .primary
                )
            }


            Divider()


            // MARK: Purchase Information

            HStack(
                alignment: .top
            ) {

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {

                    Label(
                        sourceName,
                        systemImage:
                            isOnline
                            ? "globe"
                            : "building.2"
                    )


                    Label(
                        formattedDate,
                        systemImage:
                            "calendar"
                    )
                }
                .font(
                    .caption
                )
                .foregroundStyle(
                    .secondary
                )


                Spacer()


                if match.quantity > 1 {

                    VStack(
                        alignment: .trailing,
                        spacing: 2
                    ) {

                        Text(
                            "QUANTITY"
                        )
                        .font(
                            .caption2
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        Text(
                            String(
                                format:
                                    "%.0f",
                                match.quantity
                            )
                        )
                        .fontWeight(
                            .semibold
                        )
                    }
                }
            }


            if !priceAdjustments.isEmpty {

                HistoricalPriceAdjustmentSection(
                    adjustments: priceAdjustments,
                    purchaseDate: match.date
                )
            }


            // MARK: Guidance

            HStack(
                alignment: .top,
                spacing: 8
            ) {

                Image(
                    systemName:
                        "info.circle"
                )


                Text(
                    statusMessage
                )
            }
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )


            // MARK: Receipt / Order Identifier

            if match.hasWarehouseReceiptBarcode {

                Button {

                    showExpandedBarcode = true

                } label: {

                    VStack(
                        spacing: 7
                    ) {

                        Image(
                            uiImage:
                                generateBarcode(
                                    from:
                                        match.barcode
                                )
                        )
                        .resizable()
                        .interpolation(
                            .none
                        )
                        .scaledToFit()
                        .frame(
                            height: 64
                        )


                        Text(
                            "Warehouse Receipt Barcode"
                        )
                        .font(
                            .caption2
                        )
                        .foregroundStyle(
                            .secondary
                        )


                        Label(
                            "Tap to Enlarge",
                            systemImage:
                                "arrow.up.left.and.arrow.down.right"
                        )
                        .font(
                            .caption2
                        )
                        .foregroundStyle(
                            .blue
                        )
                    }
                    .frame(
                        maxWidth:
                            .infinity
                    )
                    .contentShape(
                        Rectangle()
                    )
                }
                .buttonStyle(
                    .plain
                )


            } else if isOnline {

                VStack(
                    alignment: .leading,
                    spacing: 2
                ) {

                    Text(
                        "ORDER"
                    )
                    .font(
                        .caption2
                    )
                    .foregroundStyle(
                        .secondary
                    )


                    Text(
                        match.barcode
                    )
                    .font(
                        .caption
                    )
                    .fontWeight(
                        .medium
                    )
                }

            } else {

                Text(
                    "Original receipt barcode not available"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }


            // MARK: Save

            Button {

                saveCardToPhotos()

            } label: {

                HStack(
                    spacing: 8
                ) {

                    if isSaving {

                        ProgressView()
                            .tint(
                                .white
                            )


                    } else {

                        Image(
                            systemName:
                                "square.and.arrow.down"
                        )
                    }


                    Text(
                        isSaving
                        ? "Saving…"
                        : "Save to Photos"
                    )
                    .fontWeight(
                        .semibold
                    )
                }
                .frame(
                    maxWidth:
                        .infinity
                )
                .padding(
                    14
                )
            }
            .buttonStyle(
                .borderedProminent
            )
            .disabled(
                isSaving
            )


            if let saveMessage {

                Text(
                    saveMessage
                )
                .font(
                    .caption
                )
                .foregroundStyle(
                    saveMessage ==
                    "Saved to Photos!"
                    ? .green
                    : .red
                )
                .frame(
                    maxWidth:
                        .infinity,
                    alignment:
                        .center
                )
            }
        }
        .padding(18)
        .background(
            Color(
                UIColor
                    .secondarySystemBackground
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
        .overlay {

            RoundedRectangle(
                cornerRadius: 18
            )
            .stroke(
                statusColor
                    .opacity(0.45),
                lineWidth: 1
            )
        }
        .shadow(
            color:
                Color.black
                    .opacity(0.06),
            radius: 6,
            x: 0,
            y: 2
        )
        .fullScreenCover(
            isPresented:
                $showExpandedBarcode
        ) {

            ExpandedReceiptBarcodeView(
                receiptIdentifier:
                    match.barcode
            )
        }
    }


    // MARK: - Price Box

    private func priceBox(
        title: String,
        amount: Double,
        color: Color
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 4
        ) {

            Text(
                title.uppercased()
            )
            .font(
                .caption2
            )
            .fontWeight(
                .semibold
            )
            .foregroundStyle(
                .secondary
            )


            Text(
                amount,
                format:
                    .currency(
                        code: "USD"
                    )
            )
            .font(
                .title3
            )
            .fontWeight(
                .bold
            )
            .foregroundStyle(
                color
            )
        }
        .frame(
            maxWidth:
                .infinity,
            alignment:
                .leading
        )
        .padding(12)
        .background(
            Color(
                UIColor
                    .tertiarySystemBackground
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 12
            )
        )
    }


    // MARK: - Save Card

    private func saveCardToPhotos() {

        isSaving = true
        saveMessage = nil


        PhotoCardSaver.save(
            match:
                match,
            newPrice:
                newPrice
        ) {
            success in


            isSaving =
                false


            if success {

                saveMessage =
                    "Saved to Photos!"


            } else {

                saveMessage =
                    "Unable to save photo."
            }
        }
    }
}


// MARK: - Historical Price Adjustments

struct HistoricalPriceAdjustmentSection: View {

    let adjustments: [PriceAdjustmentRecord]
    let purchaseDate: String


    var body: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Label(
                "Previous Adjustment for This Item",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.subheadline.bold())
            .foregroundStyle(.orange)


            ForEach(adjustments) { adjustment in

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text(
                        "\(formattedDate(adjustment.adjustmentDate)) • \(formattedWarehouse(adjustment.warehouse))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)


                    HStack(spacing: 0) {

                        Text(
                            adjustment.adjustmentAmount,
                            format: .currency(code: "USD")
                        )

                        Text(" adjustment")

                        if let quantity = adjustment.adjustedQuantity {

                            Text(
                                " • Qty \(formattedQuantity(quantity))"
                            )
                        }
                    }
                    .font(.caption.weight(.semibold))

                    if let subtitle = relativeSubtitle(for: adjustment) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }


                if adjustment.id != adjustments.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            Color.orange.opacity(0.08)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    Color.orange.opacity(0.22),
                    lineWidth: 1
                )
        }
    }


    private func formattedDate(_ value: String) -> String {

        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"

        guard let date = input.date(
            from: String(value.prefix(10))
        ) else {
            return value
        }

        return date.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .year()
        )
    }


    private func parsedDate(_ value: String) -> Date? {

        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"

        return input.date(
            from: String(value.prefix(10))
        )
    }


    private func relativeSubtitle(
        for adjustment: PriceAdjustmentRecord
    ) -> String? {

        guard
            let adjustmentDate = parsedDate(adjustment.adjustmentDate),
            let displayedPurchaseDate = parsedDate(purchaseDate)
        else {
            return nil
        }

        if adjustmentDate < displayedPurchaseDate {
            return "From an earlier purchase"
        }

        if adjustmentDate > displayedPurchaseDate {
            return "Recorded after this purchase"
        }

        return nil
    }


    private func formattedWarehouse(_ value: String) -> String {

        let cleanValue = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        return cleanValue.isEmpty
            ? "Unknown Warehouse"
            : cleanValue.localizedCapitalized
    }


    private func formattedQuantity(_ value: Double) -> String {

        if value.rounded() == value {
            return String(format: "%.0f", value)
        }

        return String(format: "%g", value)
    }
}


// MARK: - Expanded Warehouse Barcode

struct ExpandedReceiptBarcodeView: View {

    @Environment(\.dismiss)
    private var dismiss

    let receiptIdentifier: String

    @State
    private var previousBrightness: CGFloat? = nil


    private var encodedPayload: String {

        costcoBarcodePayload(
            from: receiptIdentifier
        ) ?? receiptIdentifier
    }


    private var activeScreen: UIScreen? {

        UIApplication.shared
            .connectedScenes
            .compactMap {
                $0 as? UIWindowScene
            }
            .first {
                $0.activationState ==
                    .foregroundActive
            }?
            .screen
    }


    var body: some View {

        NavigationStack {

            GeometryReader {
                geometry in

                let isLandscape =
                    geometry.size.width >
                    geometry.size.height

                ScrollView(
                    .vertical,
                    showsIndicators: true
                ) {

                    VStack(
                        spacing:
                            isLandscape
                            ? 16
                            : 24
                    ) {

                        Text(
                            "Present this barcode at Costco"
                        )
                        .font(
                            isLandscape
                            ? .subheadline
                            : .headline
                        )
                        .foregroundStyle(
                            .secondary
                        )
                        .padding(
                            .top,
                            isLandscape
                            ? 8
                            : 20
                        )


                        VStack(
                            spacing:
                                isLandscape
                                ? 14
                                : 22
                        ) {

                            Image(
                                uiImage:
                                    generateBarcode(
                                        from:
                                            receiptIdentifier
                                    )
                            )
                            .resizable()
                            .interpolation(
                                .none
                            )
                            .scaledToFit()
                            .frame(
                                maxWidth:
                                    .infinity
                            )
                            .frame(
                                height:
                                    isLandscape
                                    ? 155
                                    : 220
                            )
                            .padding(
                                .horizontal,
                                isLandscape
                                ? 20
                                : 10
                            )


                            Text(
                                receiptIdentifier
                            )
                            .font(
                                isLandscape
                                ? .body.monospaced()
                                : .title3.monospaced()
                            )
                            .foregroundStyle(
                                .black
                            )
                            .textSelection(
                                .enabled
                            )
                            .minimumScaleFactor(
                                0.7
                            )
                            .lineLimit(
                                1
                            )


                            if (
                                encodedPayload !=
                                receiptIdentifier
                            ) {

                                Text(
                                    "Barcode data: \(encodedPayload)"
                                )
                                .font(
                                    .caption
                                        .monospaced()
                                )
                                .foregroundStyle(
                                    .secondary
                                )
                                .textSelection(
                                    .enabled
                                )
                                .minimumScaleFactor(
                                    0.65
                                )
                                .lineLimit(
                                    1
                                )
                            }
                        }
                        .padding(
                            isLandscape
                            ? 20
                            : 28
                        )
                        .frame(
                            maxWidth:
                                .infinity
                        )
                        .background(
                            Color.white
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius:
                                    20
                            )
                        )
                        .shadow(
                            color:
                                Color.black
                                    .opacity(0.08),
                            radius:
                                5,
                            x: 0,
                            y: 2
                        )


                        Label(
                            "Screen brightness is temporarily increased for scanning.",
                            systemImage:
                                "sun.max.fill"
                        )
                        .font(
                            .caption
                        )
                        .foregroundStyle(
                            .secondary
                        )
                        .multilineTextAlignment(
                            .center
                        )


                        Spacer(
                            minLength: 20
                        )
                    }
                    .padding(
                        .horizontal,
                        isLandscape
                        ? 30
                        : 16
                    )
                    .padding(
                        .bottom,
                        30
                    )
                    .frame(
                        minHeight:
                            geometry.size.height,
                        alignment:
                            .top
                    )
                }
                .background(
                    Color(
                        UIColor
                            .systemGroupedBackground
                    )
                    .ignoresSafeArea()
                )
            }
            .navigationTitle(
                "Warehouse Receipt"
            )
            .navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {

                ToolbarItem(
                    placement:
                        .topBarTrailing
                ) {

                    Button(
                        "Done"
                    ) {

                        dismiss()
                    }
                    .fontWeight(
                        .semibold
                    )
                }
            }
            .onAppear {

                OrientationManager.shared
                    .allowBarcodeRotation()

                increaseBrightness()
            }
            .onDisappear {

                restoreBrightness()

                OrientationManager.shared
                    .lockToPortrait()
            }
        }
    }


    // MARK: - Brightness

    private func increaseBrightness() {

        guard
            previousBrightness == nil,
            let screen =
                activeScreen
        else {
            return
        }


        previousBrightness =
            screen.brightness


        screen.brightness =
            1.0
    }


    private func restoreBrightness() {

        guard
            let previousBrightness,
            let screen =
                activeScreen
        else {
            return
        }


        screen.brightness =
            previousBrightness
    }
}

// MARK: - Tap Outside Keyboard Dismissal

private struct KeyboardDismissTapCatcher: UIViewRepresentable {

    let onTapOutside: () -> Void


    func makeCoordinator() -> Coordinator {

        Coordinator(
            onTapOutside: onTapOutside
        )
    }


    func makeUIView(
        context: Context
    ) -> UIView {

        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false

        DispatchQueue.main.async {

            context.coordinator.install(
                in: view.window
            )
        }

        return view
    }


    func updateUIView(
        _ uiView: UIView,
        context: Context
    ) {

        context.coordinator.onTapOutside =
            onTapOutside

        DispatchQueue.main.async {

            context.coordinator.install(
                in: uiView.window
            )
        }
    }


    static func dismantleUIView(
        _ uiView: UIView,
        coordinator: Coordinator
    ) {

        coordinator.uninstall()
    }


    final class Coordinator:
        NSObject,
        UIGestureRecognizerDelegate {

        var onTapOutside: () -> Void

        private weak var installedWindow: UIWindow?
        private var tapRecognizer: UITapGestureRecognizer?


        init(
            onTapOutside:
                @escaping () -> Void
        ) {

            self.onTapOutside =
                onTapOutside
        }


        func install(
            in window: UIWindow?
        ) {

            guard let window else {
                return
            }

            if installedWindow === window,
               tapRecognizer != nil {

                return
            }

            uninstall()

            let recognizer =
                UITapGestureRecognizer(
                    target: self,
                    action: #selector(
                        handleTap
                    )
                )

            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self

            window.addGestureRecognizer(
                recognizer
            )

            installedWindow = window
            tapRecognizer = recognizer
        }


        func uninstall() {

            if let tapRecognizer {

                installedWindow?
                    .removeGestureRecognizer(
                        tapRecognizer
                    )
            }

            tapRecognizer = nil
            installedWindow = nil
        }


        @objc
        private func handleTap() {

            installedWindow?
                .endEditing(true)

            onTapOutside()
        }


        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {

            var view: UIView? = touch.view

            while let currentView = view {

                // Preserve normal cursor placement, long-press,
                // and double-tap selection inside text fields.
                if currentView is UITextField ||
                   currentView is UITextView {

                    return false
                }

                // Do not hijack buttons and other controls.
                if currentView is UIControl {

                    return false
                }

                view = currentView.superview
            }

            return true
        }
    }
}
