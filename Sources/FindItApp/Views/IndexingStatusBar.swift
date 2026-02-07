import SwiftUI

/// 索引进度圆环
///
/// 工具栏右侧的紧凑型进度指示器（18pt 圆环）。
/// 仅在后台索引进行中时显示。
/// - 悬停：popover 显示当前处理详情
/// - 单击圆环或 popover：弹出详细进度 sheet
struct IndexingProgressRing: View {
    let indexingManager: IndexingManager
    @State private var showDetail = false
    @State private var isHovering = false

    private let ringSize: CGFloat = 16
    private let lineWidth: CGFloat = 1.5

    var body: some View {
        if indexingManager.isIndexing {
            ring
                .onTapGesture { openDetail() }
                .onHover { hovering in
                    if !showDetail { isHovering = hovering }
                }
                .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                    hoverCard
                }
                .sheet(isPresented: $showDetail) {
                    IndexingDetailSheet(indexingManager: indexingManager)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("索引进度 \(Int(progress * 100))%")
        }
    }

    private func openDetail() {
        isHovering = false
        showDetail = true
    }

    // MARK: - 圆环

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    progressColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: ringSize, height: ringSize)
        .contentShape(Circle())
    }

    // MARK: - 悬浮卡片

    /// popover 内容，点击可打开详细 sheet
    private var hoverCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "film")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let name = indexingManager.currentVideoName {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("准备中...")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if let stage = indexingManager.currentStage {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(stage)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("\(doneVideos)/\(totalVideos) 个视频")
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(10)
        .frame(width: 200)
        .contentShape(Rectangle())
        .onTapGesture {
            openDetail()
        }
    }

    // MARK: - 进度计算

    private var totalVideos: Int {
        indexingManager.folderProgress.values.reduce(0) { $0 + $1.totalVideos }
    }

    private var doneVideos: Int {
        indexingManager.folderProgress.values.reduce(0) { $0 + $1.completedVideos + $1.failedVideos }
    }

    private var progress: CGFloat {
        guard totalVideos > 0 else { return 0 }
        return CGFloat(doneVideos) / CGFloat(totalVideos)
    }

    private var progressColor: Color {
        let hasErrors = indexingManager.folderProgress.values.contains { $0.failedVideos > 0 }
        return hasErrors ? .orange.opacity(0.7) : .secondary.opacity(0.5)
    }
}
