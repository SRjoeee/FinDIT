import SwiftUI

/// 搜索空状态视图
///
/// 仅显示一个居中 logo，零文字。参考 Downie / Permute 风格。
struct EmptyStateView: View {
    var body: some View {
        Image(systemName: "sparkle.magnifyingglass")
            .font(.system(size: 72, weight: .ultraLight))
            .foregroundStyle(.quaternary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
