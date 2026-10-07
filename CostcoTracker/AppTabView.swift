import SwiftUI

struct AppTabView: View {

    var body: some View {

        TabView {

            ContentView()
                .tabItem {
                    Label(
                        "Scan",
                        systemImage: "camera.viewfinder"
                    )
                }

            PriceMatchesView()
                .tabItem {
                    Label(
                        "Price Matches",
                        systemImage: "tag.fill"
                    )
                }

            SavedReturnsView()
                .tabItem {
                    Label(
                        "Returns",
                        systemImage: "arrow.uturn.backward.circle.fill"
                    )
                }
        }
    }
}
