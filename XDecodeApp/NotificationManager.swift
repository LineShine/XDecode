import Foundation
import UserNotifications
import XDecodeCore

struct NotificationPresentation: Equatable, Sendable {
    let title: String
    let playsSound: Bool
}

@MainActor
final class NotificationManager {
    private var center: UNUserNotificationCenter?
    private let delegate = NotificationCenterDelegate()

    func configure() {
        guard center == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        configure()
        guard let center else { return false }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func send(_ result: DecodeResult) {
        configure()
        guard let center else { return }
        let presentation = Self.presentation(for: result)
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.sound = presentation.playsSound ? .default : nil
        let request = UNNotificationRequest(
            identifier: result.id.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    nonisolated static func presentation(for result: DecodeResult) -> NotificationPresentation {
        let fileName = result.request.sourceURL.lastPathComponent

        switch result.state {
        case .completed:
            return NotificationPresentation(
                title: "✅ \(fileName)解密成功",
                playsSound: false
            )
        case .partiallyCompleted:
            return NotificationPresentation(
                title: "⚠️ \(fileName)部分成功",
                playsSound: false
            )
        case .completedWithWarning:
            return NotificationPresentation(
                title: "⚠️ \(fileName)解密成功，源文件删除失败",
                playsSound: false
            )
        case .failed:
            return NotificationPresentation(
                title: "❌ \(fileName)\(failureSummary(for: result.message))",
                playsSound: true
            )
        }
    }

    private nonisolated static func failureSummary(for message: String) -> String {
        if message.contains("缺少匹配") || message.contains("没有匹配") {
            return "缺少匹配密钥"
        }
        if message.contains("密钥不匹配") || message.contains("私钥不匹配") {
            return "密钥不匹配或日志损坏"
        }
        if message.contains("源文件不存在") {
            return "源文件不存在"
        }
        if message.contains("文件为空") || message.contains("结果为空") {
            return "内容为空"
        }
        if message.contains("解压失败") {
            return "解压失败"
        }
        if message.contains("内容损坏") || message.contains("损坏数据") {
            return "日志损坏"
        }
        return "解密失败"
    }
}

private final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
