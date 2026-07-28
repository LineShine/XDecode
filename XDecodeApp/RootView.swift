import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                if settings.automaticEnabled {
                    HStack(spacing: 7) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("自动解密运行中").font(.caption)
                        Spacer()
                    }
                    .padding(12)
                }
            }
        } detail: {
            Group {
                switch model.selectedSection {
                case .decode: DecodeView()
                case .history: HistoryView()
                case .monitor: MonitorView()
                case .finder: FinderIntegrationView()
                case .settings: SettingsView()
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { model.chooseFiles() } label: { Label("添加日志", systemImage: "plus") }
                }
            }
        }
        .alert("永久删除源日志", isPresented: $model.deletionConfirmationPresented) {
            Button("取消", role: .cancel) { model.cancelPermanentDeletion() }
            Button("确认并继续", role: .destructive) { model.confirmPermanentDeletion() }
        } message: {
            Text("XDecode 会在单个日志完整成功后永久删除源日志。ZIP 批量不会删除源 ZIP，也不需要此确认。")
        }
        .alert("XDecode", isPresented: Binding(
            get: { model.bannerMessage != nil },
            set: { if !$0 { model.bannerMessage = nil } }
        )) {
            Button("好") { model.bannerMessage = nil }
        } message: {
            Text(model.bannerMessage ?? "")
        }
    }
}
