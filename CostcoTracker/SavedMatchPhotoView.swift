
import SwiftUI

// Display-only formatting for purchase dates stored as "yyyy-MM-dd".
// Falls back to the original string if it cannot be parsed.
private func formattedMatchDate(_ value: String) -> String {

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

struct SavedMatchPhotoView: View {

    // The receipt record found in our database.
    let match: ReceiptMatch

    // The current Costco shelf price.
    let newPrice: Double

    // Determines which eligibility message to show. An online order is never
    // a warehouse price-adjustment candidate, regardless of the 30-day window.
    private var statusText: String {
        if match.isOnlineOrder {
            return "ONLINE ORDER"
        } else if match.qualifies {
            return "WITHIN 30-DAY ADJUSTMENT WINDOW"
        } else if match.savings > 0 {
            return "OUTSIDE 30-DAY ADJUSTMENT WINDOW"
        } else {
            return "NO PRICE DIFFERENCE"
        }
    }

    private var statusColor: Color {
        if match.isOnlineOrder {
            return .blue
        }
        return match.qualifies ? .green : .orange
    }

    var body: some View {

        VStack(spacing: 24) {

            // MARK: - Header

            Text(match.isOnlineOrder ? "COSTCO ONLINE PRICE CHECK" : "COSTCO PRICE MATCH")
                .font(.system(size: 38, weight: .heavy))
                .foregroundColor(.blue)

            Text(match.description)
                .font(.system(size: 42, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundColor(.black)

            Text("ITEM #\(match.itemNumber)")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.gray)

            Divider()

            // MARK: - Prices

            HStack(spacing: 20) {

                priceBox(
                    title: "PRICE PAID",
                    amount: match.unitPrice,
                    color: .black
                )

                priceBox(
                    title: "CURRENT PRICE",
                    amount: newPrice,
                    color: .green
                )
            }

            // MARK: - Savings

            VStack(spacing: 8) {

                Text(match.isOnlineOrder ? "PRICE DIFFERENCE" : "POTENTIAL SAVINGS")
                    .font(.system(size: 27, weight: .semibold))

                Text(String(format: "$%.2f", match.savings))
                    .font(.system(size: 60, weight: .heavy))

            }
            .foregroundColor(.green)
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.green.opacity(0.10))
            .cornerRadius(20)

            Divider()

            // MARK: - Receipt Details

            detailRow(
                title: "Purchase Date",
                value: formattedMatchDate(match.date)
            )

            detailRow(
                title: match.isOnlineOrder ? "Source" : "Warehouse",
                value: match.warehouse
            )

            detailRow(
                title: "Quantity",
                value: String(format: "%.0f", match.quantity)
            )

            Divider()

            // MARK: - Receipt Identifier

            if match.hasWarehouseReceiptBarcode {

                Image(uiImage: generateBarcode(from: match.barcode))
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(height: 130)
                    .padding(.horizontal, 25)

                Text("RECEIPT BARCODE")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.gray)

            } else if match.isOnlineOrder {

                detailRow(
                    title: "Online Order Number",
                    value: match.barcode
                )

            } else {

                Text("Original scannable barcode was not stored for this receipt.")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            // MARK: - Eligibility

            Text(statusText)
                .font(.system(size: 23, weight: .bold))
                .foregroundColor(statusColor)
                .multilineTextAlignment(.center)

        }
        .padding(45)
        .frame(width: 1080)
        .background(Color.white)
    }

    // MARK: - Reusable Price Box

    private func priceBox(
        title: String,
        amount: Double,
        color: Color
    ) -> some View {

        VStack(spacing: 12) {

            Text(title)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.gray)

            Text(String(format: "$%.2f", amount))
                .font(.system(size: 45, weight: .bold))
                .foregroundColor(color)

        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(18)
    }

    // MARK: - Reusable Detail Row

    private func detailRow(
        title: String,
        value: String
    ) -> some View {

        HStack {

            Text(title)
                .foregroundColor(.gray)

            Spacer()

            Text(value)
                .foregroundColor(.black)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)

        }
        .font(.system(size: 26))
    }
}
