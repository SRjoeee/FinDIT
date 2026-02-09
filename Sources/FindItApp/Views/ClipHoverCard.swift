import SwiftUI
import FindItCore

/// 悬浮信息卡
///
/// 鼠标悬停 clip 卡片 700ms 后弹出，显示完整元数据：
/// 描述、标签 pills、场景类型、转录文本片段。
struct ClipHoverCard: View {
    let result: SearchEngine.SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 描述（完整显示，不截断）
            if let desc = result.clipDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 标签
            if !tagsList.isEmpty {
                tagsPills
            }

            Divider()

            // 场景
            if let scene = result.scene, !scene.isEmpty {
                Label(scene, systemImage: "film")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 转录文本
            if let transcript = result.transcript, !transcript.isEmpty {
                Label {
                    Text(transcript)
                        .lineLimit(3)
                } icon: {
                    Image(systemName: "text.quote")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // 时间码
            HStack(spacing: 12) {
                Label(formatTimecode(result.startTime), systemImage: "clock")
                if let file = result.fileName {
                    Label(file, systemImage: "doc")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 260)
    }

    // MARK: - Tags

    private static let decoder = JSONDecoder()

    private var tagsList: [String] {
        guard let json = result.tags, !json.isEmpty,
              let data = json.data(using: .utf8),
              let array = try? Self.decoder.decode([String].self, from: data) else {
            return []
        }
        return array
    }

    @ViewBuilder
    private var tagsPills: some View {
        // 简单换行布局：用 HStack + wrap 模拟
        let tags = tagsList.prefix(8)
        WrappingHStack(spacing: 4) {
            ForEach(Array(tags), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1), in: Capsule())
            }
        }
    }

    private func formatTimecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - WrappingHStack

/// 简单换行 HStack 布局
///
/// 子视图水平排列，超出宽度自动换行到下一行。
/// 使用 SwiftUI Layout 协议实现。
struct WrappingHStack: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            guard index < subviews.count else { break }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                // 换行
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = y + rowHeight
        }

        return LayoutResult(
            size: CGSize(width: maxWidth, height: totalHeight),
            positions: positions
        )
    }
}
