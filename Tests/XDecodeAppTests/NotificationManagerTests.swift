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

        #expect(presentation.title == "✅ sample.xlog (耗时 10 ms) 解密成功")
        #expect(!presentation.playsSound)
    }

    @Test("Missing-key notification is concise")
    func missingKey() throws {
        let result = try makeResult(
            state: .failed,
            message: "解密失败：Xlog 部分解密；2 个加密帧缺少匹配私钥；未生成 .log"
        )

        let presentation = NotificationManager.presentation(for: result)

        #expect(presentation.title == "❌ sample.xlog (耗时 10 ms) 缺少匹配密钥")
        #expect(presentation.playsSound)
    }

    @Test("Generic failure does not expose verbose diagnostics")
    func genericFailure() throws {
        let result = try makeResult(
            state: .failed,
            message: "日志内容损坏：未找到有效的 Xlog 数据帧"
        )

        #expect(NotificationManager.presentation(for: result).title == "❌ sample.xlog (耗时 10 ms) 日志损坏")
    }

    @Test("Source deletion warning remains distinct from decode failure")
    func deletionWarning() throws {
        let result = try makeResult(
            state: .completedWithWarning,
            message: "解密完成，但源文件删除失败"
        )

        #expect(
            NotificationManager.presentation(for: result).title
                == "⚠️ sample.xlog (耗时 10 ms) 解密成功，源文件删除失败"
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
        #expect(presentation.title == "⚠️ 123_456.zip (耗时 10 ms) 部分成功")
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
        let skipped = try makeResult(
            state: .skipped,
            message: "ZIP 中没有符合当前规则的日志"
        )
        let controller = StatusItemController()
        controller.update(results: [skipped, success, missingKey])
        let menu = NSMenu()

        controller.menuNeedsUpdate(menu)

        let titles = menu.items.map(\.title)
        #expect(titles.contains("✅ sample.xlog (耗时 10 ms) 解密成功"))
        #expect(titles.contains("❌ sample.xlog (耗时 10 ms) 缺少匹配密钥"))
        #expect(!titles.contains { $0.contains("已跳过") })
        #expect(!titles.contains { $0.contains("· 完成") || $0.contains("· 失败") })
    }

    @Test("Finder reveal uses output when available and retained source after failure")
    func finderRevealTargets() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/sample.xlog")
        let outputURL = URL(fileURLWithPath: "/tmp/sample.log")
        let success = try makeResult(
            state: .completed,
            message: "解密完成",
            sourceURL: sourceURL,
            outputURL: outputURL,
            sourceDeleted: true
        )
        let failure = try makeResult(
            state: .failed,
            message: "解密失败",
            sourceURL: sourceURL
        )

        #expect(success.finderRevealURL == outputURL)
        #expect(failure.finderRevealURL == sourceURL)
    }

    @Test("Duration levels use the one-second and three-second boundaries")
    func durationLevels() throws {
        let fast = try makeResult(state: .completed, message: "完成", durationMilliseconds: 999)
        let warningStart = try makeResult(state: .completed, message: "完成", durationMilliseconds: 1_000)
        let warningEnd = try makeResult(state: .completed, message: "完成", durationMilliseconds: 3_000)
        let slow = try makeResult(state: .completed, message: "完成", durationMilliseconds: 3_001)

        #expect(fast.durationLevel == .fast)
        #expect(warningStart.durationLevel == .warning)
        #expect(warningEnd.durationLevel == .warning)
        #expect(slow.durationLevel == .slow)
    }

    private func makeResult(
        state: DecodeState,
        message: String,
        sourceURL: URL = URL(fileURLWithPath: "/tmp/sample.xlog"),
        outputURL: URL? = nil,
        sourceDeleted: Bool = false,
        durationMilliseconds: Int = 10
    ) throws -> DecodeResult {
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        let request = try DecodeRequest(
            sourceURL: sourceURL,
            origin: .automatic,
            requestedAt: requestedAt
        )
        return DecodeResult(
            request: request,
            state: state,
            outputURL: outputURL,
            message: message,
            sourceDeleted: sourceDeleted,
            finishedAt: requestedAt.addingTimeInterval(Double(durationMilliseconds) / 1_000)
        )
    }
}
