import SwiftUI

/// 索引详细进度 Sheet
///
/// 点击 IndexingStatusBar 弹出，展示每个文件夹的索引进度和错误信息。
struct IndexingDetailSheet: View {
    let indexingManager: IndexingManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("索引进度")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if indexingManager.folderProgress.isEmpty {
                ContentUnavailableView(
                    "暂无索引任务",
                    systemImage: "tray",
                    description: Text("添加文件夹后将自动开始索引")
                )
            } else {
                List {
                    ForEach(sortedFolders, id: \.key) { path, progress in
                        FolderProgressSection(
                            folderPath: path,
                            progress: progress,
                            isCurrent: indexingManager.currentFolder == path,
                            currentVideoName: indexingManager.currentVideoName,
                            currentStage: indexingManager.currentStage
                        )
                    }
                }
            }

            // 底部取消按钮
            if indexingManager.isIndexing {
                Divider()
                HStack {
                    Spacer()
                    Button("取消索引") {
                        indexingManager.cancelIndexing()
                        dismiss()
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 400)
    }

    /// 按路径排序的文件夹进度列表
    private var sortedFolders: [(key: String, value: FolderIndexProgress)] {
        indexingManager.folderProgress.sorted { $0.key < $1.key }
    }
}

// MARK: - FolderProgressSection

private struct FolderProgressSection: View {
    let folderPath: String
    let progress: FolderIndexProgress
    let isCurrent: Bool
    let currentVideoName: String?
    let currentStage: String?

    var body: some View {
        Section {
            // 进度条
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(progress.completedVideos) 完成")
                        .foregroundStyle(.green)
                    if progress.failedVideos > 0 {
                        Text("\(progress.failedVideos) 失败")
                            .foregroundStyle(.orange)
                    }
                    if progress.sttSkippedNoAudioVideos > 0 {
                        Text("\(progress.sttSkippedNoAudioVideos) 无音轨")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(progress.completedVideos + progress.failedVideos)/\(progress.totalVideos)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                ProgressView(value: progress.progress)
                    .tint(progress.failedVideos > 0 ? .orange : .accentColor)

                // 当前正在处理
                if isCurrent, let name = currentVideoName {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let stage = currentStage {
                            Text("— \(stage)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
            }

            // 错误列表
            if !progress.nonFatalIssues.isEmpty {
                DisclosureGroup("已降级 (\(progress.nonFatalIssues.count))") {
                    ForEach(Array(progress.nonFatalIssues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: issue.path).lastPathComponent)
                                .font(.caption)
                            Text(issue.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            }

            if !progress.errors.isEmpty {
                DisclosureGroup("错误 (\(progress.errors.count))") {
                    ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: error.path).lastPathComponent)
                                .font(.caption)
                            Text(error.message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } header: {
            Label {
                Text(URL(fileURLWithPath: folderPath).lastPathComponent)
            } icon: {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusIcon: String {
        if isCurrent { return "arrow.triangle.2.circlepath" }
        if progress.isComplete && progress.failedVideos == 0 { return "checkmark.circle.fill" }
        if progress.isComplete && progress.failedVideos > 0 { return "exclamationmark.triangle.fill" }
        return "clock"
    }

    private var statusColor: Color {
        if isCurrent { return .accentColor }
        if progress.isComplete && progress.failedVideos == 0 { return .green }
        if progress.failedVideos > 0 { return .orange }
        return .secondary
    }
}
