import SwiftUI
import AppKit
import GRDB
import FindItCore

/// 搜索结果卡片
///
/// 显示缩略图、描述摘要、文件名和时间码。
/// 点击选中，悬停 700ms 显示悬浮信息卡。
struct ClipCard: View {
    let result: SearchEngine.SearchResult
    let isSelected: Bool
    var isOffline: Bool = false
    var globalDB: DatabasePool?
    var onSelect: () -> Void = {}

    @State private var isHovering = false
    @State private var showHoverCard = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var lastClickTime: Date?
    @State private var showTagEditor = false

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
        .onTapGesture {
            let now = Date()
            if let last = lastClickTime,
               now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
                // 双击 → 打开视频
                lastClickTime = nil
                guard let path = result.filePath else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else {
                // 单击 → 选中
                lastClickTime = now
                onSelect()
            }
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
        if let path = result.filePath {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }

        Button("复制时间码") {
            let timecode = formatTimecode(result.startTime)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(timecode, forType: .string)
        }

        if let path = result.filePath {
            Button("复制文件路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }

        Divider()

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

    // MARK: - Rating & Color Actions

    private func setRating(_ rating: Int) {
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: result.sourceFolder)
            try folderDB.write { db in
                try ClipLabel.updateRating(db, clipId: result.sourceClipId, rating: rating)
            }
            syncToGlobal()
        } catch {
            print("[ClipCard] 设置评分失败: \(error)")
        }
    }

    private func setColorLabel(_ label: ColorLabel?) {
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: result.sourceFolder)
            try folderDB.write { db in
                try ClipLabel.updateColorLabel(db, clipId: result.sourceClipId, label: label)
            }
            syncToGlobal()
        } catch {
            print("[ClipCard] 设置颜色标签失败: \(error)")
        }
    }

    private func syncToGlobal() {
        guard let gdb = globalDB else { return }
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: result.sourceFolder)
            _ = try SyncEngine.sync(
                folderPath: result.sourceFolder,
                folderDB: folderDB,
                globalDB: gdb,
                force: true
            )
        } catch {
            print("[ClipCard] 同步失败: \(error)")
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
