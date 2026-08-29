import SwiftUI

@main
struct LocalWebShareApp: App {
    @StateObject private var fileStore = FileStore()
    @StateObject private var webServer = LocalWebServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(fileStore)
                .environmentObject(webServer)
        }
    }
}
