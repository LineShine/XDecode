# XDecode Windows

Windows 版本位于独立解决方案 `XDecode.Windows.sln`，目标为 Windows 10
22H2 / Windows 11 x64。Swift 工程继续作为协议和行为参考，不参与 Windows 构建。

## 环境

- Windows 11，安装支持 .NET 10 / Windows App SDK 2.3.1 的 Visual Studio，
  并选择“使用 C++ 的桌面开发”和“Windows 应用开发”工作负载。
- .NET 10 SDK 和 Windows 10 SDK 10.0.26100。
- vcpkg 固定到 `56bb2411609227288b70117ead2c47585ba07713`。

## 构建

```powershell
git clone https://github.com/microsoft/vcpkg.git .vcpkg
git -C .vcpkg checkout 56bb2411609227288b70117ead2c47585ba07713
.\.vcpkg\bootstrap-vcpkg.bat -disableMetrics
.\.vcpkg\vcpkg.exe install --x-manifest-root=Windows `
  --x-install-root=Windows\vcpkg_installed --triplet=x64-windows

dotnet restore Windows\XDecode.Windows.sln -p:Platform=x64
dotnet test Windows\tests\XDecode.Core.Tests\XDecode.Core.Tests.csproj -c Release `
  -p:Platform=x64 -p:VcpkgInstalledDir="$PWD\Windows\vcpkg_installed"
dotnet test Windows\tests\XDecode.Application.Tests\XDecode.Application.Tests.csproj -c Release `
  -p:Platform=x64 -p:VcpkgInstalledDir="$PWD\Windows\vcpkg_installed"
dotnet test Windows\tests\XDecode.Windows.Tests\XDecode.Windows.Tests.csproj -c Release `
  -p:Platform=x64 -p:VcpkgInstalledDir="$PWD\Windows\vcpkg_installed"
```

Release 构建：

```powershell
msbuild Windows\XDecode.Windows.sln /m /restore `
  /p:Configuration=Release /p:Platform=x64 `
  /p:VcpkgInstalledDir="$PWD\Windows\vcpkg_installed" `
  /p:AppxPackageSigningEnabled=false
```

MSIX 的 Publisher 必须与测试证书 Subject 一致。PFX 和密码只通过 CI Secret
`WINDOWS_SIGNING_PFX_BASE64`、`WINDOWS_SIGNING_PASSWORD` 注入，不得提交到仓库。

## 项目

- `src/XDecode.Core`：解码协议、限制、单文件和 ZIP 事务。
- `src/XDecode.Application`：规则、DPAPI 设置、历史、队列、监听和更新检查。
- `src/XDecode.Windows`：WinUI 3、托盘、通知、启动任务和单实例激活。
- `src/XDecode.ExplorerCommand`：只转发普通文件的原生 `IExplorerCommand`。
- `packaging`：文件关联、COM、StartupTask 和自包含 MSIX。

ZIP 的 Windows 路径校验额外拒绝 UNC、盘符、ADS、设备名、非法字符、末尾空格或点、
符号链接和特殊条目。单文件完整发布后才永久删除源文件；ZIP 永远保留。

Windows 10/11 的手工安装与系统集成验收项见 [`ACCEPTANCE.md`](ACCEPTANCE.md)。
