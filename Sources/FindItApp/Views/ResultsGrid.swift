import SwiftUI
import AppKit
import GRDB
import FindItCore

/// 搜索结果网格
///
/// 使用 LazyVGrid 自适应布局展示搜索结果卡片。
/// 列数随窗口宽度自动调整（最小卡片宽度 200px）。
/// 支持键盘方向键导航和批量多选（⌘+Click / ⇧+Click）。
struct ResultsGrid: View {
    let results: [SearchEngine.SearchResult]
    let resultCount: Int
    let offlineFolders: Set<String>
    var globalDB: DatabasePool?
    @Binding var selectedClipIds: Set<Int64>
    @Binding var focusedClipId: Int64?
    @Binding var selectionAnchorId: Int64?
    @Binding var columnsPerRow: Int
    @Binding var scrollOnSelect: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(results, id: \.clipId) { result in
                        ClipCard(
                            result: result,
                            isSelected: selectedClipIds.contains(result.clipId),
                            multiSelectCount: selectedClipIds.count,
                            isOffline: offlineFolders.contains(result.sourceFolder),
                            globalDB: globalDB,
                            onSelect: { modifiers in
                                handleClick(clipId: result.clipId, modifiers: modifiers)
                            },
                            selectedResults: selectedResults
                        )
                        .id(result.clipId)
                    }
                }
                .padding(16)
                .onChange(of: focusedClipId) {
                    guard scrollOnSelect, let id = focusedClipId else { return }
                    scrollOnSelect = false
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { columnsPerRow = Self.calculateColumns(width: geo.size.width) }
                    .onChange(of: geo.size.width) {
                        let cols = Self.calculateColumns(width: geo.size.width)
                        if cols != columnsPerRow { columnsPerRow = cols }
                    }
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("\(resultCount) 个片段")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)

                if selectedClipIds.count > 1 {
                    Text("已选 \(selectedClipIds.count) 个")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Click Handling

    /// Finder 风格的点击选中逻辑
    private func handleClick(clipId: Int64, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            // ⌘+Click: toggle
            if selectedClipIds.contains(clipId) {
                selectedClipIds.remove(clipId)
                if focusedClipId == clipId {
                    focusedClipId = selectedClipIds.first
                }
            } else {
                selectedClipIds.insert(clipId)
                focusedClipId = clipId
            }
            selectionAnchorId = clipId
        } else if modifiers.contains(.shift), let anchorId = selectionAnchorId {
            // ⇧+Click: 范围选中
            guard let anchorIndex = results.firstIndex(where: { $0.clipId == anchorId }),
                  let clickIndex = results.firstIndex(where: { $0.clipId == clipId }) else {
                // Fallback: 单选
                selectedClipIds = [clipId]
                focusedClipId = clipId
                selectionAnchorId = clipId
                return
            }
            let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
            selectedClipIds = Set(results[range].map(\.clipId))
            focusedClipId = clipId
            // Shift+Click 不更新 anchor (Finder 行为)
        } else {
            // 普通点击: 单选
            selectedClipIds = [clipId]
            focusedClipId = clipId
            selectionAnchorId = clipId
        }
    }

    /// 当前选中的 SearchResult 集合（供批量上下文菜单使用）
    private var selectedResults: [SearchEngine.SearchResult] {
        results.filter { selectedClipIds.contains($0.clipId) }
    }

    /// 根据容器宽度计算自适应列数
    ///
    /// 匹配 `GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 12)` 的布局逻辑。
    static func calculateColumns(width: CGFloat) -> Int {
        let padding: CGFloat = 32 // 16 * 2
        let spacing: CGFloat = 12
        let minWidth: CGFloat = 200
        let available = width - padding
        return max(1, Int((available + spacing) / (minWidth + spacing)))
    }
}
