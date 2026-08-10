import AppKit
import Foundation
import UniversalExtractorCore

@MainActor
final class OpenFileRouter: ObservableObject {
    static let shared = OpenFileRouter()

    @Published private(set) var generation = 0
    private var pendingURLs: [URL] = []
    private var pendingQuietly = false
    private var quietJobIDs: Set<UUID> = []
    private var terminationScheduled = false

    private init() {}

    func enqueue(_ urls: [URL], quietly: Bool) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        pendingURLs.append(contentsOf: fileURLs)
        pendingQuietly = pendingQuietly || quietly
        generation += 1
    }

    func takePending() -> (urls: [URL], quietly: Bool) {
        defer {
            pendingURLs.removeAll()
            pendingQuietly = false
        }
        return (pendingURLs, pendingQuietly)
    }

    func trackQuietJobs(_ ids: [UUID], quietly: Bool) {
        guard quietly else { return }
        guard !ids.isEmpty else {
            guard !terminationScheduled else { return }
            terminationScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
            return
        }
        quietJobIDs.formUnion(ids)
        enforceQuietPresentation()
    }

    func finishQuietlyIfPossible(jobs: [ArchiveJob]) {
        guard !quietJobIDs.isEmpty, !terminationScheduled else { return }
        let tracked = jobs.filter { quietJobIDs.contains($0.id) }
        guard tracked.count == quietJobIDs.count, tracked.allSatisfy({ $0.state.isTerminal }) else { return }
        terminationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    func revealForInteraction(keepQuietJobTracking: Bool = false) {
        if !keepQuietJobTracking {
            quietJobIDs.removeAll()
            terminationScheduled = false
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func enforceQuietPresentation() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
        NSApp.windows.forEach { $0.orderOut(nil) }
        // SwiftUI 可能在打开文件事件之后才创建首个窗口，再执行一次以避免闪现。
        DispatchQueue.main.async {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchUptime = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        route(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in OpenFileRouter.shared.revealForInteraction() }
        return false
    }

    /// Finder 右键菜单“服务 → 使用万能解压”的接收方法。
    @objc func extractArchives(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        var urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        if urls.isEmpty,
           let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }

        guard !urls.isEmpty else {
            error.pointee = AppLocalization.text("没有收到可解压的文件。") as NSString
            return
        }
        route(urls)
    }

    private func route(_ urls: [URL]) {
        let isLaunchInvocation = ProcessInfo.processInfo.systemUptime - launchUptime < 3
        let hasVisibleWindow = NSApp.windows.contains(where: { $0.isVisible })
        let quietly = isLaunchInvocation || !hasVisibleWindow
        Task { @MainActor in
            OpenFileRouter.shared.enqueue(urls, quietly: quietly)
            if quietly { OpenFileRouter.shared.enforceQuietPresentation() }
        }
    }
}
