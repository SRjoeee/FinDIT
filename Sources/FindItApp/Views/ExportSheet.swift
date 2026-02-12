import SwiftUI
import UniformTypeIdentifiers
import FindItCore

/// NLE 导出配置 Sheet
///
/// 支持 FCPXML 和 EDL 两种格式导出。
/// 通过 NSSavePanel 选择保存位置后写入文件。
struct ExportSheet: View {
    let clips: [SearchEngine.SearchResult]
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .fcpxml
    @State private var fps: Double = 24
    @State private var projectName: String = "FindIt Export"
    @State private var dropFrame: Bool = false
    @State private var includeKeywords: Bool = true
    @State private var includeNotes: Bool = true
    @State private var errorMessage: String?
    @State private var isExporting: Bool = false

    enum ExportFormat: String, CaseIterable, Identifiable {
        case fcpxml = "FCPXML"
        case edl = "EDL"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .fcpxml: return "fcpxml"
            case .edl: return "edl"
            }
        }

        var description: String {
            switch self {
            case .fcpxml: return "Final Cut Pro XML (DaVinci Resolve, FCP, Premiere)"
            case .edl: return "CMX 3600 EDL (DaVinci Resolve, Premiere, Avid)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("导出到 NLE")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            Form {
                Picker("格式", selection: $format) {
                    ForEach(ExportFormat.allCases) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }

                Text(format.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("项目名称", text: $projectName)

                Picker("帧率", selection: $fps) {
                    Text("23.976").tag(23.976)
                    Text("24").tag(24.0)
                    Text("25").tag(25.0)
                    Text("29.97").tag(29.97)
                    Text("30").tag(30.0)
                    Text("50").tag(50.0)
                    Text("59.94").tag(59.94)
                    Text("60").tag(60.0)
                }

                Toggle("Drop Frame Timecode", isOn: $dropFrame)
                    .disabled(!Timecode.isDropFrameRate(fps))

                if format == .edl {
                    Toggle("包含元数据注释", isOn: $includeNotes)
                } else {
                    Toggle("包含关键词", isOn: $includeKeywords)
                    Toggle("包含备注", isOn: $includeNotes)
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            // Footer
            HStack {
                Text("\(clips.count) 个片段")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("导出...") { exportAction() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(clips.isEmpty || projectName.isEmpty || isExporting)
            }
            .padding()
        }
        .frame(width: 420, height: 400)
        .onChange(of: fps) {
            // 切换帧率时自动关闭 drop frame（如果新帧率不支持）
            if !Timecode.isDropFrameRate(fps) {
                dropFrame = false
            }
        }
    }

    // MARK: - Export Action

    private func exportAction() {
        let panel = NSSavePanel()
        panel.title = "导出 \(format.rawValue)"
        panel.nameFieldStringValue = "\(projectName).\(format.fileExtension)"

        // 设置文件类型
        if let utType = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [utType]
        } else {
            panel.allowedContentTypes = format == .fcpxml ? [.xml] : [.plainText]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // 捕获当前值（避免在 Task 中引用 self）
        let currentFormat = format
        let currentClips = clips
        let currentProjectName = projectName
        let currentFps = fps
        let currentIncludeKeywords = includeKeywords
        let currentIncludeNotes = includeNotes
        let currentDropFrame = dropFrame

        isExporting = true
        Task {
            do {
                switch currentFormat {
                case .fcpxml:
                    let videoFormats = await FCPXMLExporter.probeVideoFormats(clips: currentClips)
                    let options = FCPXMLExporter.Options(
                        projectName: currentProjectName,
                        fps: currentFps,
                        includeKeywords: currentIncludeKeywords,
                        includeNotes: currentIncludeNotes,
                        dropFrame: currentDropFrame
                    )
                    try FCPXMLExporter.export(
                        clips: currentClips, to: url.path,
                        options: options, videoFormats: videoFormats
                    )

                case .edl:
                    let options = EDLExporter.Options(
                        title: currentProjectName,
                        fps: currentFps,
                        dropFrame: currentDropFrame,
                        includeComments: currentIncludeNotes
                    )
                    try EDLExporter.export(clips: currentClips, to: url.path, options: options)
                }
                dismiss()
            } catch {
                errorMessage = "导出失败: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }
}
