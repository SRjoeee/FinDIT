import SwiftUI
import AppKit
import FindItCore

/// 搜索结果卡片
///
/// 显示缩略图、描述摘要、文件名和时间码。
/// 点击选中，悬停 700ms 显示悬浮信息卡。
struct ClipCard: View {
    let result: SearchEngine.SearchResult
    let isSelected: Bool
    var onSelect: () -> Void = {}

    @State private var isHovering = false
    @State private var showHoverCard = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 缩略图区域
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(path: result.thumbnailPath)

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
        .onTapGesture { onSelect() }
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
