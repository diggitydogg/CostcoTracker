import SwiftUI


struct PriceMatchesView: View {

    @StateObject private var priceQueue =
        PriceMatchQueue.shared

    @State private var saveMessage: String? = nil
    @State private var saveMessageItemID: UUID? = nil
    @State private var savingItemID: UUID? = nil

    @State private var showClearConfirmation = false

    @State private var barcodePresentation:
        PriceMatchBarcodePresentation? = nil


    // MARK: - Summary Values

    private var qualifyingCount: Int {

        priceQueue.items.filter {
            $0.qualifies
        }
        .count
    }


    private var otherPriceDropCount: Int {

        priceQueue.items.count -
            qualifyingCount
    }


    // MARK: - Main View

    var body: some View {

        NavigationStack {

            Group {

                if priceQueue.items.isEmpty {

                    emptyView

                } else {

                    queueView
                }
            }
            .navigationTitle(
                "Price Matches"
            )
        }
        .confirmationDialog(
            "Clear all saved price matches?",
            isPresented:
                $showClearConfirmation,
            titleVisibility:
                .visible
        ) {

            Button(
                "Clear All",
                role: .destructive
            ) {

                priceQueue.clear()

                saveMessage = nil
                saveMessageItemID = nil
                savingItemID = nil
            }


            Button(
                "Cancel",
                role: .cancel
            ) { }

        } message: {

            Text(
                "This removes every saved price match from the app."
            )
        }
        .fullScreenCover(
            item:
                $barcodePresentation
        ) { presentation in

            ExpandedReceiptBarcodeView(
                receiptIdentifier:
                    presentation.receiptIdentifier
            )
        }
    }


    // MARK: - Empty Queue

    private var emptyView: some View {

        VStack(
            spacing: 18
        ) {

            Spacer()


            Image(
                systemName:
                    "tag.slash"
            )
            .font(
                .system(
                    size: 58
                )
            )
            .foregroundStyle(
                .secondary
            )


            Text(
                "No Price Matches Saved"
            )
            .font(
                .title2.bold()
            )


            Text(
                "Scan a Costco shelf placard from the Scan tab, then add any matching purchases you want to keep here."
            )
            .multilineTextAlignment(
                .center
            )
            .foregroundStyle(
                .secondary
            )
            .padding(
                .horizontal,
                34
            )


            Spacer()
        }
        .frame(
            maxWidth:
                .infinity,
            maxHeight:
                .infinity
        )
        .background(
            Color(
                uiColor:
                    .systemGroupedBackground
            )
        )
    }


    // MARK: - Queue

    private var queueView: some View {

        List {

            Section {
                summaryCard
                    .listRowInsets(
                        EdgeInsets(
                            top: 16,
                            leading: 16,
                            bottom: 8,
                            trailing: 16
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                ForEach(
                    priceQueue.items
                ) { item in

                    priceMatchCard(
                        item
                    )
                    .listRowInsets(
                        EdgeInsets(
                            top: 8,
                            leading: 16,
                            bottom: 8,
                            trailing: 16
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            priceQueue.remove(item)
                        } label: {
                            Label(
                                "Delete",
                                systemImage: "trash"
                            )
                        }
                        .tint(.red)
                    }
                }
            }

            Section {
                Button(
                    role: .destructive
                ) {

                    showClearConfirmation =
                        true

                } label: {

                    Label(
                        "Clear All Price Matches",
                        systemImage:
                            "trash"
                    )
                    .fontWeight(
                        .semibold
                    )
                    .frame(
                        maxWidth: .infinity,
                        alignment: .center
                    )
                }
                .listRowInsets(
                    EdgeInsets(
                        top: 8,
                        leading: 16,
                        bottom: 18,
                        trailing: 16
                    )
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(
                    .vertical,
                    10
                )
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(
            Color(
                uiColor:
                    .systemGroupedBackground
            )
        )
    }


    // MARK: - Summary

    private var summaryCard: some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {

            HStack(
                alignment: .top
            ) {

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {

                    Text(
                        "POTENTIAL SAVINGS"
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
                        priceQueue.totalSavings,
                        format:
                            .currency(
                                code: "USD"
                            )
                    )
                    .font(
                        .system(
                            size: 36,
                            weight: .bold
                        )
                    )
                }


                Spacer()


                Image(
                    systemName:
                        "tag.fill"
                )
                .font(
                    .system(
                        size: 28
                    )
                )
                .foregroundStyle(
                    .blue
                )
                .padding(12)
                .background(
                    Color.blue
                        .opacity(0.10)
                )
                .clipShape(
                    Circle()
                )
            }


            Divider()


            HStack(
                spacing: 0
            ) {

                summaryStat(
                    value:
                        "\(priceQueue.items.count)",
                    label:
                        "Saved"
                )


                Divider()
                    .frame(
                        height: 38
                    )


                summaryStat(
                    value:
                        "\(qualifyingCount)",
                    label:
                        "Within 30 Days"
                )


                if otherPriceDropCount > 0 {

                    Divider()
                        .frame(
                            height: 38
                        )


                    summaryStat(
                        value:
                            "\(otherPriceDropCount)",
                        label:
                            "Other"
                    )
                }
            }


            Text(
                "Potential savings are based on the shelf or current price you entered. Final adjustment eligibility is determined by Costco."
            )
            .font(
                .caption
            )
            .foregroundStyle(
                .secondary
            )
        }
        .padding(18)
        .background(
            Color.white
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 18
            )
        )
        .shadow(
            color:
                Color.black
                    .opacity(0.06),
            radius: 5,
            x: 0,
            y: 2
        )
    }


    private func summaryStat(
        value: String,
        label: String
    ) -> some View {

        VStack(
            spacing: 3
        ) {

            Text(
                value
            )
            .font(
                .headline
            )
            .fontWeight(
                .bold
            )


            Text(
                label
            )
            .font(
                .caption2
            )
            .foregroundStyle(
                .secondary
            )
            .multilineTextAlignment(
                .center
            )
        }
        .frame(
            maxWidth:
                .infinity
        )
    }


    // MARK: - Individual Price Match

    private func priceMatchCard(
        _ item: QueuedPriceMatch
    ) -> some View {

        let online =
            isOnline(
                item
            )

        let statusColor:
            Color =
                online
                ? .blue
                : (
                    item.qualifies
                    ? .green
                    : .orange
                )

        let statusTitle =
            online
            ? "Online Purchase"
            : (
                item.qualifies
                ? "Within 30 Days"
                : "Outside 30 Days"
            )

        let priceAdjustments =
            DBManager.shared.priceAdjustments(
                for: item.itemNumber
            )


        return VStack(
            alignment: .leading,
            spacing: 16
        ) {

            // MARK: Header

            HStack(
                alignment: .top,
                spacing: 12
            ) {

                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {

                    Text(
                        item.description
                    )
                    .font(
                        .headline
                    )
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )


                    HStack(
                        spacing: 8
                    ) {

                        Text(
                            "Item #\(item.itemNumber)"
                        )
                        .textSelection(.enabled)


                        if item.quantity > 1 {

                            Text(
                                "• Qty \(String(format: "%.0f", item.quantity))"
                            )
                        }
                    }
                    .font(
                        .caption
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }


                Spacer(
                    minLength: 8
                )
            }


            // MARK: Purchase History

            NavigationLink {
                ItemPurchaseHistoryView(
                    itemNumber: item.itemNumber
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


            // MARK: Status

            Label(
                statusTitle,
                systemImage:
                    online
                    ? "globe"
                    : (
                        item.qualifies
                        ? "checkmark.circle.fill"
                        : "clock.fill"
                    )
            )
            .font(
                .caption.bold()
            )
            .foregroundStyle(
                statusColor
            )
            .padding(
                .horizontal,
                10
            )
            .padding(
                .vertical,
                6
            )
            .background(
                statusColor
                    .opacity(0.10)
            )
            .clipShape(
                Capsule()
            )


            // MARK: Savings

            HStack {

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text(
                        "YOU SAVE"
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
                        item.savings,
                        format:
                            .currency(
                                code: "USD"
                            )
                    )
                    .font(
                        .title2
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


            // MARK: Price Comparison

            HStack(
                spacing: 10
            ) {

                priceBox(
                    title:
                        "You Paid",
                    amount:
                        item.unitPrice,
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
                        online
                        ? "Current Price"
                        : "Shelf Price",
                    amount:
                        item.newPrice,
                    color:
                        .green
                )
            }


            Divider()


            // MARK: Purchase Information

            HStack(
                alignment: .top
            ) {

                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {

                    Label(
                        sourceName(
                            item
                        ),
                        systemImage:
                            online
                            ? "globe"
                            : "building.2"
                    )


                    Label(
                        formattedDate(
                            item.date
                        ),
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
            }


            if !priceAdjustments.isEmpty {

                HistoricalPriceAdjustmentSection(
                    adjustments: priceAdjustments,
                    purchaseDate: item.date
                )
            }


            // MARK: Barcode / Order Number

            if item.hasWarehouseReceiptBarcode {

                Button {

                    barcodePresentation =
                        PriceMatchBarcodePresentation(
                            receiptIdentifier:
                                item.barcode
                        )

                } label: {

                    VStack(
                        spacing: 7
                    ) {

                        Image(
                            uiImage:
                                generateBarcode(
                                    from:
                                        item.barcode
                                )
                        )
                        .resizable()
                        .interpolation(
                            .none
                        )
                        .scaledToFit()
                        .frame(
                            height: 60
                        )


                        Label(
                            "Tap Receipt Barcode to Enlarge",
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

            } else if online {

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {

                    Text(
                        "ONLINE ORDER"
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
                        item.barcode
                    )
                    .font(
                        .caption.monospaced()
                    )
                    .textSelection(
                        .enabled
                    )
                }
                .padding(12)
                .frame(
                    maxWidth:
                        .infinity,
                    alignment:
                        .leading
                )
                .background(
                    Color(
                        uiColor:
                            .secondarySystemGroupedBackground
                    )
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12
                    )
                )

            } else {

                Text(
                    "Original receipt barcode not available"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }


            // MARK: Save Card

            Button {

                saveToPhotos(
                    item
                )

            } label: {

                HStack(
                    spacing: 8
                ) {

                    if savingItemID ==
                        item.id {

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
                        savingItemID ==
                        item.id
                        ? "Saving…"
                        : "Save Card to Photos"
                    )
                    .fontWeight(
                        .semibold
                    )
                }
                .frame(
                    maxWidth:
                        .infinity
                )
                .padding(13)
            }
            .buttonStyle(
                .borderedProminent
            )
            .disabled(
                savingItemID != nil
            )


            if saveMessageItemID ==
                item.id,
               let saveMessage {

                Text(
                    saveMessage
                )
                .font(
                    .caption
                )
                .foregroundStyle(
                    saveMessage
                        .hasPrefix("Saved")
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
            Color.white
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
                    .opacity(0.30),
                lineWidth: 1
            )
        }
        .shadow(
            color:
                Color.black
                    .opacity(0.05),
            radius: 4,
            x: 0,
            y: 2
        )
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
                .headline
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
                uiColor:
                    .secondarySystemGroupedBackground
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 12
            )
        )
    }


    // MARK: - Helpers

    private func isOnline(
        _ item: QueuedPriceMatch
    ) -> Bool {

        item.warehouse
            .hasPrefix(
                "Online Order"
            )
    }


    private func sourceName(
        _ item: QueuedPriceMatch
    ) -> String {

        if isOnline(
            item
        ) {

            return "Costco.com"
        }


        return item.warehouse
    }


    private func formattedDate(
        _ rawDate: String
    ) -> String {

        let input =
            DateFormatter()

        input.locale =
            Locale(
                identifier:
                    "en_US_POSIX"
            )

        input.dateFormat =
            "yyyy-MM-dd"


        guard
            let date =
                input.date(
                    from:
                        String(
                            rawDate.prefix(10)
                        )
                )
        else {

            return rawDate
        }


        let output =
            DateFormatter()

        output.locale =
            Locale.current

        output.dateFormat =
            "MMM d, yyyy"


        return output.string(
            from: date
        )
    }


    // MARK: - Save One Card

    private func saveToPhotos(
        _ item: QueuedPriceMatch
    ) {

        savingItemID =
            item.id

        saveMessage = nil
        saveMessageItemID = nil


        PhotoCardSaver.save(
            match:
                item.receiptMatch,
            newPrice:
                item.newPrice
        ) { success in

            DispatchQueue.main.async {

                savingItemID =
                    nil

                saveMessageItemID =
                    item.id


                saveMessage =
                    success
                    ? "Saved to Photos!"
                    : "Unable to save the card."
            }
        }
    }
}


// MARK: - Barcode Presentation

private struct PriceMatchBarcodePresentation:
    Identifiable {

    let id = UUID()

    let receiptIdentifier: String
}
