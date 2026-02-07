import SwiftUI
import FindItCore

/// 搜索结果网格
///
/// 使用 LazyVGrid 自适应布局展示搜索结果卡片。
/// 列数随窗口宽度自动调整（最小卡片宽度 200px）。
/// 支持键盘方向键导航，选中项自动滚动到可见区域。
struct ResultsGrid: View {
    let results: [SearchEngine.SearchResult]
    let resultCount: Int
    @Binding var selectedClipId: Int64?
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
                            isSelected: result.clipId == selectedClipId,
                            onSelect: { selectedClipId = result.clipId }
                        )
                        .id(result.clipId)
                    }
                }
                .padding(16)
                .onChange(of: selectedClipId) {
                    guard scrollOnSelect, let id = selectedClipId else { return }
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
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
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
