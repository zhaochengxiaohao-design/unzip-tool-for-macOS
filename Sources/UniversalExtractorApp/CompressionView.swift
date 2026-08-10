import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversalExtractorCore

struct CompressionView: View {
    @ObservedObject var coordinator: CompressionCoordinator
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                inputCard
                optionsCard
            }
            statusCard
        }
        .frame(maxHeight: .infinity)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("待压缩项目", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                if !coordinator.inputs.isEmpty {
                    Button("清空") { coordinator.clearInputs() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(coordinator.isRunning)
                }
            }

            if coordinator.inputs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                    Text(isDropTargeted ? "松开即可添加" : "拖入文件或文件夹")
                        .font(.headline)
                    Text("可一次选择多个项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(coordinator.inputs, id: \.standardizedFileURL) { url in
                            HStack(spacing: 9) {
                                Image(systemName: itemIcon(url))
                                    .foregroundStyle(Color.accentColor)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button { coordinator.removeInput(url) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(coordinator.isRunning)
                            }
                            .padding(9)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }

            Button("选择文件或文件夹…", action: chooseInputs)
                .frame(maxWidth: .infinity)
                .disabled(coordinator.isRunning)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1.4, dash: [7]))
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("压缩设置", systemImage: "slider.horizontal.3")
                .font(.headline)

            LabeledContent("格式") {
                Picker("格式", selection: Binding(
                    get: { coordinator.format },
                    set: { coordinator.setFormat($0) }
                )) {
                    ForEach(CompressionFormat.allCases, id: \.self) { format in
                        Text(format.label).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(coordinator.isRunning)
            }

            LabeledContent("压缩级别") {
                Picker("压缩级别", selection: Binding(
                    get: { coordinator.level },
                    set: { coordinator.setLevel($0) }
                )) {
                    ForEach(CompressionLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(coordinator.isRunning || coordinator.format == .tar)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("压缩包名称").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("例如：我的文件", text: $coordinator.archiveName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(coordinator.isRunning)
                Text(AppLocalization.format("将自动添加 .%@ 扩展名", coordinator.format.fileExtension))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("保存到").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("选择…", action: chooseDestination)
                        .buttonStyle(.plain)
                        .disabled(coordinator.isRunning)
                }
                Text(coordinator.destinationURL?.path(percentEncoded: false) ?? AppLocalization.text("尚未选择保存目录"))
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if coordinator.format.supportsPassword {
                VStack(alignment: .leading, spacing: 5) {
                    Text("密码保护（可选）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    SecureField("不保存密码", text: $coordinator.password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(coordinator.isRunning)
                    Text("密码仅在本次压缩过程中保留")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("此格式不支持密码；RAR 仅支持解压。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if coordinator.format.requiresSingleRegularFile {
                Label("该格式仅支持一个普通文件", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 330)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 5) {
                Text(coordinator.detail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(coordinator.state == .failed ? .red : .primary)
                    .lineLimit(2)
                if coordinator.isRunning {
                    ProgressView(value: coordinator.progress)
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            if coordinator.isRunning {
                Button("取消", role: .destructive) { coordinator.cancel() }
            } else if coordinator.state == .completed, let output = coordinator.outputURL {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .buttonStyle(.bordered)
                Button("再次压缩") { coordinator.start() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("开始压缩") { coordinator.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(coordinator.inputs.isEmpty)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    @ViewBuilder private var statusIcon: some View {
        switch coordinator.state {
        case .compressing: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title2)
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title2)
        case .idle: Image(systemName: "archivebox").foregroundStyle(Color.accentColor).font(.title2)
        }
    }

    private func chooseInputs() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("选择要压缩的文件或文件夹")
        panel.prompt = AppLocalization.text("添加")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { coordinator.addInputs(panel.urls) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("选择压缩包保存目录")
        panel.prompt = AppLocalization.text("选择")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { coordinator.setDestination(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                if let url { Task { @MainActor in coordinator.addInputs([url]) } }
            }
        }
        return accepted
    }

    private func itemIcon(_ url: URL) -> String {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? "folder.fill" : "doc.fill"
    }
}
