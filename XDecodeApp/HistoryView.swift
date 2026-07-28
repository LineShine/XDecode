import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("历史记录").font(.title2).fontWeight(.semibold)
                    Text("保留最近 30 天的解密任务").foregroundStyle(.secondary)
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
