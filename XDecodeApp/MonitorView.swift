import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("自动解密", isOn: Binding(
                    get: { settings.automaticEnabled },
                    set: { model.setAutomaticEnabled($0) }
                ))
                if settings.monitoredFolderURLs.isEmpty {
                    Text("尚未添加监控文件夹")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.monitoredFolderURLs, id: \.path) { url in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(url.path)
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                model.removeMonitoredFolder(url)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("移除监控文件夹")
                        }
                    }
                }
                Button { model.chooseMonitoredFolders() } label: {
                    Label("添加监控文件夹", systemImage: "plus")
                }
            } header: {
                Text("下载监听")
            } footer: {
                Text("只处理开启监听后新增且符合设置规则的 Xlog、MX、日期格式 Logan 和 ZIP；文件稳定后才开始解密。")
            }

            Section("处理规则") {
                LabeledContent("输出文件", value: "原文件名.log")
                LabeledContent("ZIP 输出", value: "ZIP 同名目录")
                LabeledContent("发生重名", value: "自动追加 -1、-2…")
                LabeledContent("单个日志成功", value: "永久删除源文件")
                LabeledContent("ZIP 批量", value: "始终保留源 ZIP")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("监控文件夹")
    }
}
