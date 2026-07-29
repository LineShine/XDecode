import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("历史记录").font(.title2).fontWeight(.semibold)
                    Text("列表显示最近 30 条，磁盘保留最近 200 条且不超过 30 天")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { model.clearHistory() } label: { Label("清空记录", systemImage: "trash") }
                    .disabled(model.results.isEmpty)
            }

            if model.results.isEmpty {
                EmptyStateView(title: "暂无历史记录", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.results) { ResultRow(result: $0) }
                    .listStyle(.inset)
            }
        }
        .padding(28)
    }
}
