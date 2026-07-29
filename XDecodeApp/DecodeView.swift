import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XDecodeCore

struct DecodeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("解密日志").font(.title2).fontWeight(.semibold)
                        Text("支持 Xlog、MX、Logan 和符合规则的 ZIP").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.chooseFiles() } label: { Label("选择文件", systemImage: "doc.badge.plus") }
                        .buttonStyle(.borderedProminent)
                }

                dropZone

                HStack {
                    Text("最近5个处理").font(.headline)
                    Spacer()
                    Button("查看全部") { model.selectedSection = .history }
                        .buttonStyle(.link)
                }

                if model.results.isEmpty {
                    EmptyStateView(title: "暂无任务", systemImage: "clock", message: "解密结果会显示在这里")
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.results.prefix(5)) { result in
                            ResultRow(result: result)
                            Divider()
                        }
                    }
                }

                HStack {
                    Text("单个日志解密成功后删除源文件；ZIP 批量始终保留源 ZIP")
                    Spacer()
                    if model.activeTaskCount > 0 { ProgressView().controlSize(.small) }
                    Text(model.activeTaskCount > 0 ? "正在处理 \(model.activeTaskCount) 个任务" : "等待任务")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("拖入日志或 ZIP 即可解密").font(.headline)
            Text("可同时处理多个文件").foregroundStyle(.secondary)
            Button("浏览文件") { model.chooseFiles() }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.45))
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadFileURLs(from: providers)
            return true
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else { url = nil }
                guard let url else { return }
                Task { @MainActor in model.enqueue([url], origin: .dragAndDrop) }
            }
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultRow: View {
    let result: DecodeResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 30, height: 30)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(result.request.sourceURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("(\(result.durationText))")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(durationColor.opacity(0.75))
                        .fixedSize()
                }
                Text(result.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(result.request.format.rawValue).font(.caption).foregroundStyle(.secondary)
            if let revealURL = result.finderRevealURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(result.outputURL == nil ? "在 Finder 中显示源文件" : "在 Finder 中显示输出")
            }
        }
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch result.state {
        case .completed: "checkmark.circle.fill"
        case .partiallyCompleted: "exclamationmark.circle.fill"
        case .completedWithWarning: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch result.state {
        case .completed: .green
        case .partiallyCompleted: .orange
        case .completedWithWarning: .orange
        case .skipped: .secondary
        case .failed: .red
        }
    }

    private var durationColor: Color {
        switch result.durationLevel {
        case .fast: .green
        case .warning: .orange
        case .slow: .red
        }
    }
}
