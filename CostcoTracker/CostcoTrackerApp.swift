import SwiftUI
import UIKit


// MARK: - Orientation Control

final class OrientationManager {

    static let shared = OrientationManager()

    var supportedOrientations:
        UIInterfaceOrientationMask = .portrait


    private init() { }


    // MARK: Allow Rotation for Expanded Barcode

    func allowBarcodeRotation() {

        supportedOrientations =
            .allButUpsideDown

        refreshSupportedOrientations()
    }


    // MARK: Return App to Portrait

    func lockToPortrait() {

        supportedOrientations =
            .portrait

        refreshSupportedOrientations()

        guard
            let windowScene =
                activeWindowScene()
        else {
            return
        }


        let preferences =
            UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations:
                    .portrait
            )


        windowScene.requestGeometryUpdate(
            preferences
        )
    }


    // MARK: Find Active Scene

    private func activeWindowScene()
        -> UIWindowScene? {

        for scene
            in UIApplication.shared
                .connectedScenes {

            guard
                let windowScene =
                    scene as? UIWindowScene
            else {
                continue
            }


            if (
                windowScene.activationState ==
                .foregroundActive
            ) {

                return windowScene
            }
        }


        return nil
    }


    // MARK: Refresh Orientation Rules

    private func refreshSupportedOrientations() {

        guard
            let windowScene =
                activeWindowScene()
        else {
            return
        }


        for window
            in windowScene.windows {

            if window.isKeyWindow {

                window
                    .rootViewController?
                    .setNeedsUpdateOfSupportedInterfaceOrientations()

                break
            }
        }
    }
}


// MARK: - App Delegate

final class AppDelegate:
    NSObject,
    UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window:
            UIWindow?
    ) -> UIInterfaceOrientationMask {

        OrientationManager.shared
            .supportedOrientations
    }
}


// MARK: - Main App Tabs

struct CostcoTrackerRootView: View {

    var body: some View {

        TabView {

            // Scan

            ContentView()
                .tabItem {

                    Label(
                        "Scan",
                        systemImage:
                            "camera.viewfinder"
                    )
                }


            // Price Matches

            PriceMatchesView()
                .tabItem {

                    Label(
                        "Price Matches",
                        systemImage:
                            "tag.fill"
                    )
                }


            // Returns

            SavedReturnsView()
                .tabItem {

                    Label(
                        "Returns",
                        systemImage:
                            "arrow.uturn.backward.circle.fill"
                    )
                }
        }
        .tint(.blue)
        .onAppear {

            OrientationManager.shared
                .lockToPortrait()
        }
    }
}


// MARK: - App

@main
struct CostcoTrackerApp: App {

    @UIApplicationDelegateAdaptor(
        AppDelegate.self
    )
    private var appDelegate


    var body: some Scene {

        WindowGroup {

            CostcoTrackerRootView()
                .preferredColorScheme(.light)
        }
    }
}
