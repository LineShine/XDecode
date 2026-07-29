import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
            HStack(spacing: 0) {
                compactSidebar
                    .frame(width: isSidebarCollapsed ? 54 : 0, alignment: .leading)
                    .opacity(isSidebarCollapsed ? 1 : 0)
                    .clipped()
                    .allowsHitTesting(isSidebarCollapsed)
                    .accessibilityHidden(!isSidebarCollapsed)

                Divider()
                    .opacity(isSidebarCollapsed ? 1 : 0)
                    .frame(width: isSidebarCollapsed ? 1 : 0)

                Group {
                    switch model.selectedSection {
                    case .decode: DecodeView()
                    case .history: HistoryView()
                    case .monitor: MonitorView()
                    case .finder: FinderIntegrationView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup {
                        Button { model.chooseFiles() } label: { Label("添加日志", systemImage: "plus") }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.26), value: isSidebarCollapsed)
        }
        .alert("XDecode", isPresented: Binding(
            get: { model.bannerMessage != nil },
            set: { if !$0 { model.bannerMessage = nil } }
        )) {
            Button("好") { model.bannerMessage = nil }
        } message: {
            Text(model.bannerMessage ?? "")
        }
        .background(MainWindowReader())
    }

    private var compactSidebar: some View {
        VStack(spacing: 6) {
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element.id) { index, section in
                Button {
                    model.selectedSection = section
                } label: {
                    Image(systemName: section.icon)
                        .font(.system(size: 17))
                        .scaleEffect(model.selectedSection == section ? 1.08 : 1)
                        .animation(.easeInOut(duration: 0.16), value: model.selectedSection)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    model.selectedSection == section
                        ? Color.secondary.opacity(0.16)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .scaleEffect(isSidebarCollapsed ? 1 : 0.72)
                .opacity(isSidebarCollapsed ? 1 : 0)
                .animation(
                    .easeInOut(duration: 0.22)
                        .delay(isSidebarCollapsed ? Double(index) * 0.025 : 0),
                    value: isSidebarCollapsed
                )
                .help(section.rawValue)
                .accessibilityLabel(section.rawValue)
            }

            Spacer()

            if settings.automaticEnabled {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .padding(.bottom, 12)
                    .help("自动解密运行中")
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .frame(width: 54)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .scaleEffect(x: isSidebarCollapsed ? 1 : 0.86, y: 1, anchor: .leading)
    }
}

private struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowResolvingView {
        WindowResolvingView()
    }

    func updateNSView(_ nsView: WindowResolvingView, context: Context) {}
}

private final class WindowResolvingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        MainWindowVisibilityCoordinator.shared.attach(window)
    }
}
