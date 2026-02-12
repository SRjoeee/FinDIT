import SwiftUI
import AppKit
import GRDB
import FindItCore

/// 搜索结果卡片
///
/// 显示缩略图、描述摘要、文件名和时间码。
/// 支持单击选中、⌘+Click 多选、⇧+Click 范围选、双击打开。
/// 悬停 700ms 显示悬浮信息卡。
struct ClipCard: View {
    let result: SearchEngine.SearchResult
    let isSelected: Bool
    var multiSelectCount: Int = 0
    var isOffline: Bool = false
    var globalDB: DatabasePool?
    var onSelect: (NSEvent.ModifierFlags) -> Void = { _ in }
    var selectedResults: [SearchEngine.SearchResult] = []

    @State private var isHovering = false
    @State private var showHoverCard = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var showTagEditor = false
    @Environment(SearchState.self) private var searchState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 缩略图区域
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(path: result.thumbnailPath)

                // 离线蒙层
                if isOffline {
                    ZStack {
                        Color.black.opacity(0.4)
                        Image(systemName: "icloud.slash")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                // 多选勾选角标
                if isSelected && multiSelectCount > 1 {
                    VStack {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .background(
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 16, height: 16)
                                )
                                .padding(5)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // 片段时长角标
                Text(formatDuration(result.endTime - result.startTime))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }

            // 描述摘要
            Text(descriptionText)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            // 文件名 + 时间码
            HStack {
                Text(result.fileName ?? "未知文件")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(formatTimecode(result.startTime))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.accentColor : (isHovering ? Color.secondary.opacity(0.3) : Color.clear.opacity(0)),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            ClickCaptureView(
                onClick: { modifiers, clickCount in
                    if clickCount == 2 {
                        // 双击 → 打开视频
                        guard let path = result.filePath else { return }
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    } else {
                        onSelect(modifiers)
                    }
                },
                dragDataProvider: {
                    let clips = isSelected && selectedResults.count > 1 ? selectedResults : [result]
                    let content = FCPXMLExporter.generate(clips: clips, options: .init())
                    guard let data = content.data(using: .utf8) else { return nil }
                    return (data, "FindIt_Export.fcpxml")
                }
            )
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                hoverTask?.cancel()
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    showHoverCard = true
                }
            } else {
                hoverTask?.cancel()
                hoverTask = nil
                showHoverCard = false
            }
        }
        .popover(isPresented: $showHoverCard, arrowEdge: .trailing) {
            ClipHoverCard(result: result)
        }
        .contextMenu { contextMenuItems }
        .sheet(isPresented: $showTagEditor) {
            TagEditorSheet(
                sourceFolder: result.sourceFolder,
                sourceClipId: result.sourceClipId,
                globalDB: globalDB
            )
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        let isBatch = isSelected && selectedResults.count > 1
        let targets = isBatch ? selectedResults : [result]

        if isBatch {
            let urls = targets.compactMap { $0.filePath.map { URL(fileURLWithPath: $0) } }
            if !urls.isEmpty {
                Button("在 Finder 中显示 \(urls.count) 个文件") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
        } else if let path = result.filePath {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }

        Button(isBatch ? "复制 \(targets.count) 个时间码" : "复制时间码") {
            let timecodes = targets.map { formatTimecode($0.startTime) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(timecodes.joined(separator: "\n"), forType: .string)
        }

        if isBatch {
            let paths = targets.compactMap(\.filePath)
            if !paths.isEmpty {
                Button("复制 \(paths.count) 个文件路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                }
            }
        } else if let path = result.filePath {
            Button("复制文件路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }

        Divider()

        Button(isBatch ? "导出 \(targets.count) 个片段到 NLE..." : "导出到 NLE...") {
            NotificationCenter.default.post(
                name: .exportToNLE,
                object: nil,
                userInfo: ["clips": targets]
            )
        }

        Divider()

        if !isBatch {
            Button("管理标签…") {
                showTagEditor = true
            }

            // 评分子菜单
            Menu("评分") {
                ForEach(0...5, id: \.self) { stars in
                    Button {
                        setRating(stars)
                    } label: {
                        if stars == 0 {
                            Text("无评分")
                        } else {
                            Text(String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars))
                        }
                    }
                }
            }

            // 颜色标签子菜单
            Menu("颜色标签") {
                Button("无") { setColorLabel(nil) }
                Divider()
                ForEach(ColorLabel.allCases, id: \.rawValue) { label in
                    Button {
                        setColorLabel(label)
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(red: label.rgb.r, green: label.rgb.g, blue: label.rgb.b))
                                .frame(width: 10, height: 10)
                            Text(label.displayName)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rating & Color Actions

    private func setRating(_ rating: Int) {
        let oldRating = result.rating
        searchState.updateClipRating(clipId: result.clipId, rating: rating)

        Task.detached(priority: .userInitiated) { [result, globalDB, searchState] in
            do {
                let folderDB = try DatabaseManager.openFolderDatabase(at: result.sourceFolder)
                try await folderDB.write { db in
                    try ClipLabel.updateRating(db, clipId: result.sourceClipId, rating: rating)
                }
                try await globalDB?.write { db in
                    try ClipLabel.updateRating(db, clipId: result.clipId, rating: rating)
                }
            } catch {
                print("[ClipCard] 设置评分失败: \(error)")
                await MainActor.run {
                    searchState.updateClipRating(clipId: result.clipId, rating: oldRating)
                }
            }
        }
    }

    private func setColorLabel(_ label: ColorLabel?) {
        let oldLabel = result.colorLabel
        searchState.updateClipColorLabel(clipId: result.clipId, colorLabel: label?.rawValue)

        Task.detached(priority: .userInitiated) { [result, globalDB, searchState] in
            do {
                let folderDB = try DatabaseManager.openFolderDatabase(at: result.sourceFolder)
                try await folderDB.write { db in
                    try ClipLabel.updateColorLabel(db, clipId: result.sourceClipId, label: label)
                }
                try await globalDB?.write { db in
                    try ClipLabel.updateColorLabel(db, clipId: result.clipId, label: label)
                }
                syncFinderTag(label: label)
            } catch {
                print("[ClipCard] 设置颜色标签失败: \(error)")
                await MainActor.run {
                    searchState.updateClipColorLabel(clipId: result.clipId, colorLabel: oldLabel)
                }
            }
        }
    }

    /// 同步颜色标签到视频文件的 Finder 标签系统
    nonisolated private func syncFinderTag(label: ColorLabel?) {
        guard let filePath = result.filePath,
              FileManager.default.fileExists(atPath: filePath) else { return }
        do {
            if label != nil {
                try ClipLabel.syncFinderTag(filePath: filePath, label: label)
            } else {
                let effectiveLabel: ColorLabel?
                if let videoId = result.videoId, let db = globalDB {
                    effectiveLabel = try db.read { dbConn in
                        try ClipLabel.effectiveVideoColor(dbConn, videoId: videoId)
                    }
                } else {
                    effectiveLabel = nil
                }
                try ClipLabel.syncFinderTag(filePath: filePath, label: effectiveLabel)
            }
        } catch {
            // Finder 标签同步失败不致命（文件可能在只读卷上）
        }
    }

    // MARK: - Helpers

    private var descriptionText: String {
        if let desc = result.clipDescription, !desc.isEmpty {
            return desc
        }
        if let scene = result.scene, !scene.isEmpty {
            return scene
        }
        if let transcript = result.transcript, !transcript.isEmpty {
            return transcript
        }
        return "无描述"
    }

    /// 格式化时长: 35s → "0:35", 125s → "2:05"
    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    /// 格式化时间码: 200.5s → "03:20"
    private func formatTimecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Click Capture (AppKit Bridge)

/// NSView 桥接：捕获鼠标点击事件的修饰键和点击次数，支持拖拽到 NLE
///
/// SwiftUI 的 `onTapGesture` 不提供修饰键信息，
/// 使用 NSViewRepresentable 直接访问 NSEvent。
/// 鼠标按下后拖动超过 3px 触发拖拽会话（生成临时 FCPXML 文件）。
struct ClickCaptureView: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags, Int) -> Void
    var dragDataProvider: (() -> (data: Data, fileName: String)?)? = nil

    func makeNSView(context: Context) -> ClickCaptureNSView {
        let view = ClickCaptureNSView()
        view.onClick = onClick
        view.dragDataProvider = dragDataProvider
        return view
    }

    func updateNSView(_ nsView: ClickCaptureNSView, context: Context) {
        nsView.onClick = onClick
        nsView.dragDataProvider = dragDataProvider
    }
}

class ClickCaptureNSView: NSView, NSDraggingSource {
    var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?
    var dragDataProvider: (() -> (data: Data, fileName: String)?)?

    private var mouseDownLocation: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var didInitiateDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        mouseDownEvent = event
        didInitiateDrag = false
        onClick?(event.modifierFlags, event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didInitiateDrag, let start = mouseDownLocation else { return }
        let loc = event.locationInWindow
        guard hypot(loc.x - start.x, loc.y - start.y) > 3 else { return }

        didInitiateDrag = true
        guard let (data, fileName) = dragDataProvider?() else { return }

        // 写临时文件
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(fileName)
        try? data.write(to: tempURL)

        let dragItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        dragItem.setDraggingFrame(bounds, contents: nil as NSImage?)
        beginDraggingSession(with: [dragItem], event: mouseDownEvent ?? event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
