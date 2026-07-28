import SwiftUI

struct FinderIntegrationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finder 右键").font(.title2).fontWeight(.semibold)
                Text("从文件的快捷菜单直接进入统一解密队列").foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "doc.zipper").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text("sample.xlog")
                }
                .frame(maxWidth: .infinity, minHeight: 250)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 12) {
                    Label("使用 XDecode 解密", systemImage: "sparkles")
                        .fontWeight(.medium)
                    Divider()
                    Label("打开方式 → XDecode", systemImage: "macwindow")
                    Text("Finder 扩展适用于用户目录；“打开方式”可作为其他位置的入口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding(28)
    }
}
