import SwiftUI
import Charts

// Display-only formatting for purchase dates stored as "yyyy-MM-dd".
// Falls back to the original string if it cannot be parsed.
private func formattedPurchaseHistoryDate(_ value: String) -> String {

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

// Parses a stored purchase date ("yyyy-MM-dd", possibly with a time suffix)
// into a Date for charting. Returns nil rather than substituting a sentinel
// date; the caller omits unparseable records from the chart only.
private func parsedPurchaseDate(_ value: String) -> Date? {

    let input = DateFormatter()
    input.locale = Locale(identifier: "en_US_POSIX")
    input.dateFormat = "yyyy-MM-dd"

    return input.date(from: String(value.prefix(10)))
}

private struct PurchasePricePoint: Identifiable {
    let id = UUID()
    let date: Date
    let unitPrice: Double
    let occurrenceCount: Int
}

// Groups purchase observations that share the same parsed calendar date
// and unit price, for chart rendering only. The underlying purchase
// records are never merged/deduplicated anywhere else.
private struct PriceDateKey: Hashable {
    let date: Date
    let unitPrice: Double
}

private func formattedPurchaseHistoryQuantity(_ value: Double) -> String {
    if value.rounded() == value {
        return String(format: "%.0f", value)
    }
    return String(format: "%g", value)
}

struct ItemPurchaseHistoryView: View {

    let itemNumber: String

    @State private var purchases: [ItemPurchaseRecord] = []
    @State private var adjustments: [PriceAdjustmentRecord] = []
    @State private var returns: [ItemReturnRecord] = []

    private var itemDescription: String {
        purchases.first?.description ?? ""
    }

    private var occasionCount: Int {
        purchases.count
    }

    private var purchasedQuantity: Double {
        purchases.reduce(0) { $0 + $1.quantity }
    }

    private var returnedQuantity: Double {
        returns.reduce(0) { $0 + $1.returnedQuantity }
    }

    // Not clamped to zero: a negative value is informative (more returned
    // than this app has recorded as purchased) rather than something to hide.
    private var netQuantity: Double {
        purchasedQuantity - returnedQuantity
    }

    // Gross purchase spend. Not reconciled against returns/refunds in v1.
    private var purchaseSpend: Double {
        purchases.reduce(0) { $0 + $1.lineTotal }
    }

    private var lowestUnitPrice: Double? {
        purchases.map(\.unitPrice).min()
    }

    private var highestUnitPrice: Double? {
        purchases.map(\.unitPrice).max()
    }

    // Quantity-weighted average: purchase spend / purchased quantity.
    // Never an unweighted average of per-occasion unit prices.
    private var averageUnitPrice: Double? {
        guard purchasedQuantity.isFinite, purchasedQuantity > 0 else { return nil }
        return purchaseSpend / purchasedQuantity
    }

    // One chart point per purchase occurrence with a parseable date, then
    // grouped (for chart rendering only) by identical parsed calendar date
    // + unit price so legitimately separate same-day/same-price purchases
    // don't silently overlap into one indistinguishable dot. Records with
    // an unparseable date are omitted from the chart only; they remain in
    // every summary calculation and the Purchase History list. `purchases`
    // is already deterministically ordered (date DESC, id DESC), and the
    // grouping below preserves first-seen order before the final stable
    // sort, so same-day points keep a deterministic tie-break instead of
    // an arbitrary one.
    private var pricePoints: [PurchasePricePoint] {
        var countsByKey: [PriceDateKey: Int] = [:]
        var orderedKeys: [PriceDateKey] = []

        for purchase in purchases {
            guard let date = parsedPurchaseDate(purchase.date) else { continue }
            let key = PriceDateKey(date: date, unitPrice: purchase.unitPrice)

            if let existingCount = countsByKey[key] {
                countsByKey[key] = existingCount + 1
            } else {
                countsByKey[key] = 1
                orderedKeys.append(key)
            }
        }

        return orderedKeys
            .map { key in
                PurchasePricePoint(
                    date: key.date,
                    unitPrice: key.unitPrice,
                    occurrenceCount: countsByKey[key] ?? 1
                )
            }
            .sorted { $0.date < $1.date }
    }

    // Data-derived Y-axis domain for the price chart, so the chart focuses
    // on the actual plotted price range rather than defaulting toward a
    // zero baseline.
    private var priceChartYDomain: ClosedRange<Double> {
        let prices = pricePoints.map(\.unitPrice)

        guard let minPrice = prices.min(), let maxPrice = prices.max() else {
            return 0...1
        }

        if minPrice != maxPrice {
            let range = maxPrice - minPrice
            let padding = max(0.50, range * 0.15)
            let lower = max(0, minPrice - padding)
            let upper = maxPrice + padding
            return lower...upper
        } else {
            let padding = max(0.50, minPrice * 0.05)
            let lower = max(0, minPrice - padding)
            let upper = minPrice + padding
            return lower...upper
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                // MARK: Header

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        itemDescription.isEmpty
                            ? "Item \(itemNumber)"
                            : itemDescription
                    )
                    .font(.title2.bold())

                    Text("Costco item #\(itemNumber)")
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                if purchases.isEmpty {

                    // MARK: Empty State

                    Text("No stored purchases found for this item.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                } else {

                    // MARK: Summary

                    summaryCard
                }

                // MARK: Price History

                if !pricePoints.isEmpty {
                    priceHistorySection
                }

                // MARK: Recorded Price Adjustments

                if !adjustments.isEmpty {
                    adjustmentsSection
                }

                // MARK: Recorded Returns

                if !returns.isEmpty {
                    returnsSection
                }

                // MARK: Purchase History

                if !purchases.isEmpty {
                    purchaseHistorySection
                }

                Text(
                    "Purchase Spend (Gross) does not subtract returns or refunds. Returned Qty is reconciled at the item-number level only and is not attributed to a specific original receipt. Refund dollar amounts are not yet netted into Purchase Spend."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .padding(.bottom, 60)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Purchase History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            purchases = DBManager.shared.purchaseHistory(for: itemNumber)
            adjustments = DBManager.shared.priceAdjustments(for: itemNumber)
            returns = DBManager.shared.itemReturns(for: itemNumber)
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(spacing: 14) {

            summaryRow(
                title: "Purchase Spend (Gross)",
                value: purchaseSpend.formatted(.currency(code: "USD"))
            )

            Divider()

            summaryRow(
                title: "Purchased Qty",
                value: formattedPurchaseHistoryQuantity(purchasedQuantity)
            )

            Divider()

            summaryRow(
                title: "Returned Qty",
                value: formattedPurchaseHistoryQuantity(returnedQuantity)
            )

            Divider()

            summaryRow(
                title: "Net Qty",
                value: formattedPurchaseHistoryQuantity(netQuantity)
            )

            Divider()

            summaryRow(
                title: "Purchases",
                value: "\(occasionCount)"
            )

            Divider()

            summaryRow(
                title: "Avg Price / Unit",
                value: averageUnitPrice.map { $0.formatted(.currency(code: "USD")) } ?? "—"
            )

            Divider()

            summaryRow(
                title: "Lowest Price",
                value: lowestUnitPrice.map { $0.formatted(.currency(code: "USD")) } ?? "—"
            )

            Divider()

            summaryRow(
                title: "Highest Price",
                value: highestUnitPrice.map { $0.formatted(.currency(code: "USD")) } ?? "—"
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Price History

    private var priceHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Price History")
                .font(.headline)

            Chart {
                if pricePoints.count > 1 {
                    ForEach(pricePoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Unit Price", point.unitPrice)
                        )
                    }
                }

                ForEach(pricePoints) { point in
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Unit Price", point.unitPrice)
                    )
                    .annotation(position: .top) {
                        if point.occurrenceCount > 1 {
                            Text("\(point.occurrenceCount)×")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYScale(domain: priceChartYDomain)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount, format: .currency(code: "USD"))
                        }
                    }
                }
            }
            .frame(height: 180)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Recorded Price Adjustments

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {

            Label(
                "Recorded Price Adjustments",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.subheadline.bold())
            .foregroundStyle(.orange)

            ForEach(adjustments) { adjustment in

                VStack(alignment: .leading, spacing: 3) {

                    Text(
                        "\(formattedPurchaseHistoryDate(adjustment.adjustmentDate)) • \(adjustment.warehouse.isEmpty ? "Unknown Warehouse" : adjustment.warehouse)"
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
                            Text(" • Qty \(formattedPurchaseHistoryQuantity(quantity))")
                        }
                    }
                    .font(.caption.weight(.semibold))
                }

                if adjustment.id != adjustments.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }

    // MARK: - Recorded Returns

    private var returnsSection: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Recorded Returns")
                .font(.subheadline.bold())

            ForEach(returns) { itemReturn in

                VStack(alignment: .leading, spacing: 3) {

                    Text(formattedPurchaseHistoryDate(itemReturn.returnDate))
                        .font(.caption.weight(.semibold))

                    Text(
                        itemReturn.warehouse.isEmpty
                            ? "Unknown Warehouse"
                            : itemReturn.warehouse
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    Text(
                        "Qty \(formattedPurchaseHistoryQuantity(itemReturn.returnedQuantity)) returned"
                    )
                    .font(.caption.weight(.semibold))

                    if !itemReturn.description.isEmpty {
                        Text(itemReturn.description)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if itemReturn.id != returns.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Purchase History

    private var purchaseHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Purchase History")
                .font(.headline)

            ForEach(purchases) { purchase in

                VStack(alignment: .leading, spacing: 6) {

                    HStack {
                        Text(formattedPurchaseHistoryDate(purchase.date))
                            .font(.subheadline.weight(.semibold))

                        Spacer()

                        Text(purchase.lineTotal, format: .currency(code: "USD"))
                            .font(.subheadline.weight(.bold))
                    }

                    Text(
                        purchase.isOnlineOrder
                            ? "Source: \(purchase.warehouse)"
                            : "Warehouse: \(purchase.warehouse)"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Text("Qty \(formattedPurchaseHistoryQuantity(purchase.quantity))")
                        Text("•")
                        Text(purchase.unitPrice, format: .currency(code: "USD"))
                        Text("/ unit")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
