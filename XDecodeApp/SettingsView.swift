import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var editingXlogProfile: XlogProfile?
    @State private var editingLoganProfile: LoganProfile?

    var body: some View {
        Form {
            Section("自动化") {
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
            }

            Section("常规") {
                Toggle("开机自启动", isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { model.setLaunchAtLoginEnabled($0) }
                ))
                Toggle("通知", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                Toggle("菜单栏显示", isOn: Binding(
                    get: { settings.menuBarEnabled },
                    set: { model.setMenuBarEnabled($0) }
                ))
            }

            Section {
                ForEach(settings.zipPatternRules) { rule in
                    HStack {
                        PatternField(
                            title: "文件名正则",
                            text: Binding(
                                get: {
                                    settings.zipPatternRules.first(where: { $0.id == rule.id })?.pattern
                                        ?? rule.pattern
                                },
                                set: { settings.updateZipPatternRule(id: rule.id, pattern: $0) }
                            ),
                            defaultValue: FilenamePatternDefaults.zip
                        )
                        Button(role: .destructive) {
                            settings.removeZipPatternRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(settings.zipPatternRules.count == 1 ? "至少保留一条规则" : "删除规则")
                        .disabled(settings.zipPatternRules.count == 1)
                    }
                }
                Button {
                    settings.addZipPatternRule()
                } label: {
                    Label("新增正则规则", systemImage: "plus")
                }
            } header: {
                Text("ZIP 批量解密")
            } footer: {
                Text("任一规则匹配即可处理。成功、失败或部分成功都会生成目录；成功日志为 .log，失败日志保留原文件名和内容，源 ZIP 始终保留。")
            }

            Section {
                PatternField(
                    title: "文件名匹配",
                    text: $settings.mxFilePattern,
                    defaultValue: FilenamePatternDefaults.mx
                )
            } header: {
                Text("MX 日志")
            } footer: {
                Text("默认匹配 *.mx，支持 * 和 ? 通配符。")
            }

            Section {
                if settings.xlogProfiles.isEmpty {
                    Text("尚未配置私钥方案").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.xlogProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                Text(profile.filePattern).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { editingXlogProfile = profile } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("编辑")
                            Button(role: .destructive) { model.removeXlogProfile(profile) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("删除")
                        }
                    }
                }
                Button { editingXlogProfile = XlogProfile(name: "默认环境") } label: {
                    Label("新增方案", systemImage: "plus")
                }
            } header: {
                Text("Xlog secp256k1 私钥")
            } footer: {
                Text("私钥保存在本机 App 设置中。文件名支持 * 和 ? 通配符，多个匹配方案会自动尝试。")
            }

            Section {
                if settings.loganProfiles.isEmpty {
                    Text("尚未配置密钥方案").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.loganProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                Text(profile.filePattern).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { editingLoganProfile = profile } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("编辑")
                            Button(role: .destructive) { model.removeLoganProfile(profile) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("删除")
                        }
                    }
                }
                Button { editingLoganProfile = LoganProfile(name: "默认环境") } label: {
                    Label("新增方案", systemImage: "plus")
                }
            } header: {
                Text("Logan Key / IV")
            } footer: {
                Text("AES Key 和 IV 均至少填写 16 字节，超过部分不参与解密；完整原文保存在本机 App 设置中。文件名支持 *、? 和 yyyy-MM-dd。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .sheet(item: $editingXlogProfile) { profile in
            XlogProfileEditor(
                profile: profile,
                isNew: !settings.xlogProfiles.contains(where: { $0.id == profile.id }),
                loadPrivateKey: { try model.xlogPrivateKeyHex(for: profile) }
            ) { saved, privateKey in
                do {
                    try model.saveXlogProfile(saved, privateKeyHex: privateKey)
                    editingXlogProfile = nil
                } catch {
                    model.bannerMessage = error.localizedDescription
                }
            } onCancel: {
                editingXlogProfile = nil
            }
        }
        .sheet(item: $editingLoganProfile) { profile in
            LoganProfileEditor(
                profile: profile,
                isNew: !settings.loganProfiles.contains(where: { $0.id == profile.id }),
                loadKey: { try model.loganKey(for: profile) },
                loadIV: { try model.loganIV(for: profile) }
            ) { saved, key, iv in
                try model.saveLoganProfile(saved, key: key, iv: iv)
                editingLoganProfile = nil
            } onCancel: {
                editingLoganProfile = nil
            }
        }
    }
}

private struct XlogProfileEditor: View {
    @State var profile: XlogProfile
    @State private var privateKey = ""
    let isNew: Bool
    let loadPrivateKey: () throws -> String
    let onSave: (XlogProfile, String) -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.filePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isNew || !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Xlog 私钥方案").font(.title2).fontWeight(.semibold)
            Form {
                TextField("方案名称", text: $profile.name)
                PatternField(
                    title: "匹配文件名",
                    text: $profile.filePattern,
                    defaultValue: FilenamePatternDefaults.xlog
                )
                RevealableSecretField(
                    title: isNew ? "64 位 Hex 私钥" : "新私钥（留空保持不变）",
                    text: $privateKey,
                    loadExisting: isNew ? nil : loadPrivateKey
                )
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") { onSave(profile, privateKey) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct LoganProfileEditor: View {
    @State var profile: LoganProfile
    @State private var key = ""
    @State private var iv = ""
    @State private var errorMessage: String?
    let isNew: Bool
    let loadKey: () throws -> String
    let loadIV: () throws -> String
    let onSave: (LoganProfile, String, String) throws -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.filePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isNew || (!key.isEmpty && !iv.isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Logan 密钥方案").font(.title2).fontWeight(.semibold)
            Form {
                TextField("方案名称", text: $profile.name)
                PatternField(
                    title: "匹配文件名",
                    text: $profile.filePattern,
                    defaultValue: FilenamePatternDefaults.logan
                )
                RevealableSecretField(
                    title: isNew ? "AES Key（至少 16 字节）" : "AES Key（留空保持不变）",
                    text: $key,
                    loadExisting: isNew ? nil : loadKey
                )
                RevealableSecretField(
                    title: isNew ? "AES IV（至少 16 字节）" : "AES IV（留空保持不变）",
                    text: $iv,
                    loadExisting: isNew ? nil : loadIV
                )
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    do {
                        try onSave(profile, key, iv)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 470)
        .alert("无法保存 Logan 密钥方案", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct PatternField: View {
    let title: String
    @Binding var text: String
    let defaultValue: String

    var body: some View {
        HStack {
            TextField(title, text: $text)
            Button {
                text = defaultValue
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("恢复默认：\(defaultValue)")
        }
    }
}

private struct RevealableSecretField: View {
    let title: String
    @Binding var text: String
    let loadExisting: (() throws -> String)?
    @State private var isRevealed = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Group {
                    if isRevealed {
                        TextField(title, text: $text)
                    } else {
                        SecureField(title, text: $text)
                    }
                }
                Button(action: toggleVisibility) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isRevealed ? "隐藏密钥" : "显示密钥")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func toggleVisibility() {
        if isRevealed {
            isRevealed = false
            return
        }
        if text.isEmpty, let loadExisting {
            do {
                text = try loadExisting()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        isRevealed = true
    }
}
