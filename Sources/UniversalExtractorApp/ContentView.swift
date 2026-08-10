import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversalExtractorCore

struct ContentView: View {
    @ObservedObject var coordinator: ExtractionCoordinator
    @ObservedObject var compressionCoordinator: CompressionCoordinator
    @ObservedObject var openFileRouter: OpenFileRouter
    @AppStorage("outputMode") private var outputModeRaw = OutputMode.separateFolder.rawValue
    @State private var isDropTargeted = false
    @State private var showAbout = false
    @State private var workspaceMode = WorkspaceMode.extract

    private enum WorkspaceMode: String, CaseIterable {
        case extract
        case compress

        var label: String {
            switch self {
            case .extract: return AppLocalization.text("解压")
            case .compress: return AppLocalization.text("压缩")
            }
        }
    }

    private var outputMode: Binding<OutputMode> {
        Binding(
            get: { OutputMode(rawValue: outputModeRaw) ?? .separateFolder },
            set: { outputModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                header
                Picker("操作", selection: $workspaceMode) {
                    ForEach(WorkspaceMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                if workspaceMode == .extract {
                    destinationCard
                    dropZone
                    queueSection
                } else {
                    CompressionView(coordinator: compressionCoordinator)
                }
            }
            .padding(24)
        }
        .sheet(item: Binding(get: { coordinator.passwordRequest }, set: { if $0 == nil { coordinator.submitPassword(nil) } })) { request in
            PasswordPrompt(request: request) { coordinator.submitPassword($0) }
        }
        .sheet(item: Binding(get: { coordinator.collisionRequest }, set: { if $0 == nil { coordinator.submitCollisionPolicy(.cancel) } })) { request in
            CollisionPrompt(request: request) { coordinator.submitCollisionPolicy($0) }
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .alert("提示", isPresented: Binding(
            get: { coordinator.presentedError != nil || compressionCoordinator.presentedError != nil },
            set: {
                if !$0 {
                    coordinator.presentedError = nil
                    compressionCoordinator.presentedError = nil
                }
            }
        )) {
            Button("好", role: .cancel) { coordinator.presentedError = nil }
        } message: {
            Text(coordinator.presentedError ?? compressionCoordinator.presentedError ?? "")
        }
        .onReceive(openFileRouter.$generation) { _ in
            let pending = openFileRouter.takePending()
            if !pending.urls.isEmpty {
                let ids = coordinator.addExternalFiles(pending.urls)
                openFileRouter.trackQuietJobs(ids, quietly: pending.quietly)
            }
        }
        .onReceive(coordinator.$jobs) { jobs in
            openFileRouter.finishQuietlyIfPossible(jobs: jobs)
        }
        .onReceive(coordinator.$queueCompletionGeneration) { _ in
            // @Published 数组的逐项变更可能在极短任务中与 SwiftUI 首次订阅交错；
            // 队列空闲事件提供第二个、确定性的静默退出触发点。
            openFileRouter.finishQuietlyIfPossible(jobs: coordinator.jobs)
        }
        .onReceive(coordinator.$passwordRequest) { request in
            if request != nil {
                openFileRouter.revealForInteraction(keepQuietJobTracking: true)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 54, height: 54)
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("万能解压")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("自动识别、解压并创建常用格式压缩包")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showAbout = true } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("关于与第三方许可证")
        }
    }

    private var destinationCard: some View {
        HStack(spacing: 14) {
            Image(systemName: outputMode.wrappedValue == .separateFolder ? "folder.fill" : "archivebox.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("输出方式")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if outputMode.wrappedValue == .separateFolder {
                    Text(coordinator.destinationURL?.path(percentEncoded: false) ?? AppLocalization.text("尚未选择输出目录"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(AppLocalization.text("使用每个压缩包所在的目录，无需选择路径"))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("输出方式", selection: outputMode) {
                ForEach(OutputMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            if outputMode.wrappedValue == .separateFolder {
                Button("选择目录…", action: chooseDestination)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text(AppLocalization.text(isDropTargeted ? "松开即可加入队列" : "拖入压缩包"))
                .font(.headline)
            Text("ZIP · 7Z · RAR · TAR · GZ · BZ2 · XZ · 分卷压缩包")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("也可以在 Finder 中右键压缩包，选择“打开方式 → 万能解压”")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("选择压缩包…", action: chooseArchives)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [7]))
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("任务队列")
                    .font(.headline)
                if !coordinator.jobs.isEmpty {
                    Text("\(coordinator.jobs.count)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if coordinator.jobs.contains(where: { $0.state.isTerminal }) {
                    Button("清除已完成") { coordinator.removeFinishedJobs() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            if coordinator.jobs.isEmpty {
                ContentUnavailableView(
                    "暂无任务",
                    systemImage: "tray",
                    description: Text(emptyQueueDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(coordinator.jobs) { job in
                            JobRow(job: job, cancel: { coordinator.cancel(jobID: job.id) })
                        }
                    }
                    .padding(1)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("选择解压输出目录")
        panel.prompt = AppLocalization.text("选择")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { coordinator.setDestination(url) }
    }

    private func chooseArchives() {
        ensureDestinationIfNeeded { destinationReady in
            guard destinationReady else { return }
            let panel = NSOpenPanel()
            panel.title = AppLocalization.text("选择压缩包")
            panel.prompt = AppLocalization.text("加入队列")
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.data, .archive]
            if panel.runModal() == .OK {
                coordinator.addFiles(panel.urls, outputMode: outputMode.wrappedValue)
            }
        }
    }

    private func ensureDestinationIfNeeded(_ completion: (Bool) -> Void) {
        if outputMode.wrappedValue == .directlyIntoDestination || coordinator.destinationURL != nil {
            completion(true)
        } else {
            chooseDestination()
            completion(coordinator.destinationURL != nil)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard outputMode.wrappedValue == .directlyIntoDestination || coordinator.destinationURL != nil else {
            coordinator.presentedError = AppLocalization.text("请先选择输出目录，再拖入压缩包。")
            return false
        }
        let mode = outputMode.wrappedValue
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                if let url {
                    Task { @MainActor in coordinator.addFiles([url], outputMode: mode) }
                }
            }
        }
        return accepted
    }

    private var emptyQueueDescription: String {
        if outputMode.wrappedValue == .directlyIntoDestination {
            return AppLocalization.text("拖入压缩包，将直接解压到其所在目录")
        }
        return coordinator.destinationURL == nil
            ? AppLocalization.text("先选择输出目录，再添加压缩包")
            : AppLocalization.text("拖入或选择压缩包以开始")
    }
}

private struct JobRow: View {
    let job: ArchiveJob
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let format = job.detectedFormat {
                        Text(format.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(job.detail)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
                    .lineLimit(2)
                if !job.state.isTerminal && job.state != .queued {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 8)
            if job.state == .completed, let output = job.outputURL {
                Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .buttonStyle(.bordered)
            } else if !job.state.isTerminal {
                Button("取消", role: .destructive, action: cancel)
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title2)
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title2)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).font(.title2)
        default:
            ProgressView().controlSize(.small)
        }
    }
}

private struct PasswordPrompt: View {
    let request: PasswordRequest
    let completion: (String?) -> Void
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("需要密码", systemImage: "lock.fill").font(.title2.bold())
            Text(request.archiveName).font(.headline).lineLimit(2)
            Text(request.message).foregroundStyle(.secondary)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !password.isEmpty { completion(password) } }
            HStack {
                Button("取消", role: .cancel) { completion(nil) }
                Spacer()
                Button("继续") { completion(password) }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

private struct CollisionPrompt: View {
    let request: CollisionRequest
    let completion: (CollisionPolicy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("发现同名文件", systemImage: "doc.on.doc.fill").font(.title2.bold())
            Text(AppLocalization.format("“%@”与目标目录中的文件重名。本次任务如何处理所有冲突？", request.archiveName))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                choice("保留两者", detail: "自动为新文件追加序号", policy: .keepBoth, prominent: true)
                choice("跳过已有文件", detail: "不修改目标目录中的同名文件", policy: .skip)
                choice("覆盖已有文件", detail: "以压缩包中的文件替换原文件", policy: .overwrite)
            }
            Button("取消此任务", role: .cancel) { completion(.cancel) }
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 460)
    }

    private func choice(_ title: String, detail: String, policy: CollisionPolicy, prominent: Bool = false) -> some View {
        Button { completion(policy) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.text(title)).fontWeight(.semibold)
                    Text(AppLocalization.text(detail)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(prominent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var licenseDocument: LicenseDocument?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
            Text("万能解压").font(.title.bold())
            Text("版本 1.5.0 · Apple Silicon")
                .foregroundStyle(.secondary)
            Divider()
            Text("本应用使用 7-Zip 26.02 命令行组件。7-Zip 按 GNU LGPL 许可发布，部分代码受 unRAR 许可约束。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Link("项目主页与源代码", destination: URL(string: "https://github.com/zhaochengxiaohao-design/unzip-tool-for-macOS")!)
                Link("访问 7-Zip 官方网站", destination: URL(string: "https://www.7-zip.org/")!)
            }
            HStack {
                resourceButton("查看项目许可证", resource: "Project-License")
                resourceButton("查看 7-Zip 许可证", resource: "7-Zip-License")
                resourceButton("查看第三方声明", resource: "ThirdPartyNotices")
            }
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 560)
        .sheet(item: $licenseDocument) { document in
            LicenseDocumentView(document: document)
        }
    }

    private func resourceButton(_ title: LocalizedStringKey, resource: String) -> some View {
        Button(title) {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
            licenseDocument = LicenseDocument(title: title, contents: contents)
        }
    }
}

private struct LicenseDocument: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let contents: String
}

private struct LicenseDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    let document: LicenseDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(document.title).font(.title2.bold())
            ScrollView {
                Text(document.contents)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 520)
    }
}

struct SettingsView: View {
    @AppStorage("outputMode") private var outputModeRaw = OutputMode.separateFolder.rawValue

    var body: some View {
        Form {
            Picker("默认输出方式", selection: $outputModeRaw) {
                ForEach(OutputMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
