import Foundation

/// 键盘导航方向
///
/// 用于网格布局的方向键导航，替代 raw string 传递。
public enum NavigationDirection: String, Sendable {
    case left
    case right
    case up
    case down
}
