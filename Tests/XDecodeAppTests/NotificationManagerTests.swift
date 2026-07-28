import AppKit
import Foundation
import Testing
import XDecodeCore
@testable import XDecodeApp

@Suite("Notifications")
struct NotificationManagerTests {
    @Test("Success notification includes an icon and source filename")
    func success() throws {
        let result = try makeResult(
            state: .completed,
            message: "Xlog 解密完成：成功 4 帧，失败 0 帧；源文件已永久删除"
        )

        let presentation = NotificationManager.presentation(for: result)

        #expect(presentation.title == "✅ sample.xlog解密成功")
        #expect(!presentation.playsSound)
    }

    @Test("Missing-key notification is concise")
    func missingKey() throws {
        let result = try makeResult(
            state: .failed,
            message: "解密失败：Xlog 部分解密；2 个加密帧缺少匹配私钥；未生成 .log"
        )

        let presentation = NotificationManager.presentation(for: result)

        #expect(presentation.title == "❌ sample.xlog缺少匹配密钥")
        #expect(presentation.playsSound)
    }

    @Test("Generic failure does not expose verbose diagnostics")
    func genericFailure() throws {
        let result = try makeResult(
            state: .failed,
            message: "日志内容损坏：未找到有效的 Xlog 数据帧"
        )

        #expect(NotificationManager.presentation(for: result).title == "❌ sample.xlog日志损坏")
    }

    @Test("Source deletion warning remains distinct from decode failure")
    func deletionWarning() throws {
        let result = try makeResult(
            state: .completedWithWarning,
            message: "解密完成，但源文件删除失败"
        )

        #expect(
            NotificationManager.presentation(for: result).title
                == "⚠️ sample.xlog解密成功，源文件删除失败"
        )
        #expect(!NotificationManager.presentation(for: result).playsSound)
    }

    @Test("ZIP partial success has a concise distinct notification")
    func partialSuccess() throws {
        let result = try makeResult(
            state: .partiallyCompleted,
            message: "ZIP 批量部分成功：成功 2 个，失败 1 个",
            sourceURL: URL(fileURLWithPath: "/tmp/123_456.zip")
        )

        let presentation = NotificationManager.presentation(for: result)
        #expect(presentation.title == "⚠️ 123_456.zip部分成功")
        #expect(!presentation.playsSound)
    }

    @MainActor
    @Test("Menu bar recent tasks reuse concise notification titles")
    func menuBarRecentTasks() throws {
        let success = try makeResult(
            state: .completed,
            message: "Xlog 解密完成：成功 4 帧，失败 0 帧"
        )
        let missingKey = try makeResult(
            state: .failed,
            message: "2 个加密帧缺少匹配私钥"
        )
        let controller = StatusItemController()
        controller.update(results: [success, missingKey])
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let titles = menu.items.map(\.title)
        #expect(titles.contains("✅ sample.xlog解密成功"))
        #expect(titles.contains("❌ sample.xlog缺少匹配密钥"))
        #expect(!titles.contains { $0.contains("· 完成") || $0.contains("· 失败") })
    }

    private func makeResult(
        state: DecodeState,
        message: String,
        sourceURL: URL = URL(fileURLWithPath: "/tmp/sample.xlog")
    ) throws -> DecodeResult {
        let request = try DecodeRequest(
            sourceURL: sourceURL,
            origin: .automatic
        )
        return DecodeResult(
            request: request,
            state: state,
            outputURL: nil,
            message: message,
            sourceDeleted: false
        )
    }
}
