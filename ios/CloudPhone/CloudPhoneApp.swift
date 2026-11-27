import SwiftUI

@main
struct CloudPhoneApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

enum Theme {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.086)
    static let card = Color(red: 0.09, green: 0.106, blue: 0.133)
    static let line = Color(red: 0.15, green: 0.17, blue: 0.21)
    static let accent = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let ok = Color(red: 0.25, green: 0.70, blue: 0.50)
    static let bad = Color(red: 0.90, green: 0.33, blue: 0.29)
    static let warn = Color(red: 0.82, green: 0.60, blue: 0.13)
    static let muted = Color(red: 0.55, green: 0.58, blue: 0.64)
}
