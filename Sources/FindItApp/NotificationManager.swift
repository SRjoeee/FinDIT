import Foundation
import AppKit
import UserNotifications

/// macOS 系统通知管理
///
/// 通过 `UNUserNotificationCenter` 推送 macOS 通知。
/// 仅在 App 不在前台时发送（避免干扰用户操作）。
/// `@MainActor` 确保 `NSApp.isActive` 访问安全。
@MainActor
enum NotificationManager {

    // MARK: - 权限

    /// 通知功能是否可用（需要有效的 app bundle）
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 请求通知权限
    ///
    /// App 启动时调用一次。macOS 上首次请求会弹出系统确认弹窗。
    /// 需要有效的 app bundle，SPM 纯 executable 无法使用通知。
    static func requestPermission() {
        guard isAvailable else {
            print("[NotificationManager] 跳过：无有效 bundle identifier")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[NotificationManager] 权限请求失败: \(error)")
            } else {
                print("[NotificationManager] 通知权限: \(granted ? "已授权" : "未授权")")
            }
        }
    }

    // MARK: - 索引通知

    /// 索引完成通知
    ///
    /// - Parameters:
    ///   - folderName: 文件夹显示名称
    ///   - videoCount: 处理的视频数
    ///   - clipCount: 生成的片段数
    static func notifyIndexComplete(folderName: String, videoCount: Int, clipCount: Int) {
        guard shouldSendNotification() else { return }

        let content = UNMutableNotificationContent()
        content.title = "索引完成"
        content.body = "\(folderName): 已索引 \(videoCount) 个视频"
        content.sound = .default

        send(identifier: "findit-index-complete-\(folderName)", content: content)
    }

    /// 索引失败通知
    ///
    /// - Parameters:
    ///   - folderName: 文件夹显示名称
    ///   - failedCount: 失败的视频数
    ///   - reason: 失败原因摘要（可选）
    static func notifyIndexFailed(folderName: String, failedCount: Int, reason: String?) {
        guard shouldSendNotification() else { return }

        let content = UNMutableNotificationContent()
        content.title = "索引失败"
        content.body = "\(folderName): \(failedCount) 个文件索引失败"
        if let reason = reason {
            content.body += " — \(reason)"
        }
        content.sound = .default

        send(identifier: "findit-index-failed-\(folderName)", content: content)
    }

    // MARK: - 卷通知

    /// 硬盘恢复通知
    ///
    /// - Parameters:
    ///   - volumeName: 卷名称
    ///   - restoredFolders: 恢复的文件夹数
    static func notifyVolumeReconnected(volumeName: String, restoredFolders: Int) {
        guard shouldSendNotification() else { return }

        let content = UNMutableNotificationContent()
        content.title = "硬盘已重新连接"
        if restoredFolders > 0 {
            content.body = "\"\(volumeName)\" 已恢复，\(restoredFolders) 个文件夹将继续索引"
        } else {
            content.body = "\"\(volumeName)\" 已恢复在线"
        }
        content.sound = .default

        send(identifier: "findit-volume-reconnected-\(volumeName)", content: content)
    }

    /// 硬盘断开通知
    ///
    /// - Parameter volumeName: 卷名称
    static func notifyVolumeDisconnected(volumeName: String) {
        guard shouldSendNotification() else { return }

        let content = UNMutableNotificationContent()
        content.title = "硬盘已断开"
        content.body = "\"\(volumeName)\" 已离线，相关素材暂不可预览"

        send(identifier: "findit-volume-disconnected-\(volumeName)", content: content)
    }

    // MARK: - Private

    /// 判断是否应发送通知（需有效 bundle + App 不在前台时才发）
    private static func shouldSendNotification() -> Bool {
        isAvailable && !NSApp.isActive
    }

    /// 发送通知
    private static func send(identifier: String, content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // 立即发送
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationManager] 发送通知失败: \(error)")
            }
        }
    }
}
