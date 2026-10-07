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

// A dedicated, high-resolution image for one selected purchase.
// Unlike a price-match card, this does not suggest a new shelf price or savings.
struct ReturnReceiptCardView: View {
    let purchase: ReturnPurchase

    var body: some View {
        VStack(spacing: 24) {
            Text("COSTCO PURCHASE RECEIPT")
                .font(.system(size: 38, weight: .heavy))
                .foregroundColor(.blue)
                .multilineTextAlignment(.center)

            Text(purchase.description.isEmpty ? "Costco Item" : purchase.description)
                .font(.system(size: 42, weight: .bold))
                .foregroundColor(.black)
                .multilineTextAlignment(.center)

            Text("ITEM #\(purchase.itemNumber)")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.gray)

            Divider()

            VStack(spacing: 10) {
                Text("PRICE PAID PER UNIT")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundColor(.gray)
                Text(String(format: "$%.2f", purchase.unitPrice))
                    .font(.system(size: 62, weight: .heavy))
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(18)

            detailRow("Purchase date", formattedReturnDate(purchase.date))
            detailRow("Warehouse", purchase.warehouse)
            detailRow("Quantity", String(format: "%g", purchase.quantity))
            detailRow("Purchase line total", String(format: "$%.2f", purchase.lineTotal))

            Divider()

            if purchase.hasWarehouseReceiptBarcode {
                Image(uiImage: generateBarcode(from: purchase.receiptBarcode))
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(height: 140)
                    .padding(.horizontal, 18)
                Text(purchase.receiptBarcode)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundColor(.black)
                    .multilineTextAlignment(.center)
                Text("RECEIPT BARCODE")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.gray)
            } else if purchase.isOnlineOrder {
                detailRow("Online order ID", purchase.receiptBarcode)
                Text("Open the original online order for return details.")
                    .font(.system(size: 21))
                    .foregroundColor(.gray)
            } else {
                Text("Original scannable barcode was not stored for this receipt.")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Divider()
            Text("Purchase record from CostcoTracker. Verify the original receipt and applicable return terms with Costco.")
                .font(.system(size: 20))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(44)
        .frame(width: 1080)
        .background(Color.white)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title)
                .foregroundColor(.gray)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(.black)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 26))
    }
}
