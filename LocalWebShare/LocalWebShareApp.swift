import SwiftUI

@main
struct LocalWebShareApp: App {
    @StateObject private var fileStore = FileStore()
    @StateObject private var webServer = LocalWebServer()
    @StateObject private var networkMonitor = NetworkStatusMonitor()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(fileStore)
                .environmentObject(webServer)
                .environmentObject(networkMonitor)
        }
    }
}

private struct AppRootView: View {
    @EnvironmentObject private var networkMonitor: NetworkStatusMonitor
    @State private var showingSplash = true

    var body: some View {
        ZStack {
            ContentView()
                .opacity(showingSplash ? 0 : 1)

            if showingSplash {
                SplashView(kind: networkMonitor.kind)
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(1350))
            withAnimation(.easeOut(duration: 0.28)) {
                showingSplash = false
            }
        }
    }
}

private struct SplashView: View {
    let kind: NetworkConnectionKind

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("SharLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 118, height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(radius: 12, y: 6)

            Text("Shar")
                .font(.title.bold())

            VStack(spacing: 5) {
                Label(kind.title, systemImage: kind.systemImage)
                    .font(.subheadline.weight(.semibold))
                if !kind.detail.isEmpty {
                    Text(kind.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ProgressView()
                .padding(.bottom, 36)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
