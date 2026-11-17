import SwiftUI

@main
struct TripperMapsApp: App {
    @StateObject private var ride = RideController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ride)
                .preferredColorScheme(.dark)
        }
    }
}
