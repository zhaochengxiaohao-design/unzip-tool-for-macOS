import SwiftUI
import UniversalExtractorCore

@main
struct UniversalExtractorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = ExtractionCoordinator()
    @StateObject private var compressionCoordinator = CompressionCoordinator()
    @StateObject private var openFileRouter = OpenFileRouter.shared

    var body: some Scene {
        WindowGroup("万能解压") {
            ContentView(
                coordinator: coordinator,
                compressionCoordinator: compressionCoordinator,
                openFileRouter: openFileRouter
            )
                .frame(minWidth: 760, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)

        Settings {
            SettingsView()
        }
    }
}
