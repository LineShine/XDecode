# XDecode Windows

Windows 版本位于独立解决方案 `XDecode.Windows.sln`，目标为 Windows 10
22H2 / Windows 11 x64。Swift 工程继续作为协议和行为参考，不参与 Windows 构建。

## 环境

- Windows 11，安装支持 .NET 10 / Windows App SDK 2.3.1 的 Visual Studio，
  并选择“使用 C++ 的桌面开发”和“Windows 应用开发”工作负载。
- .NET 10 SDK 和 Windows 10 SDK 10.0.26100。
- vcpkg 固定到 `56bb2411609227288b70117ead2c47585ba07713`。
- 生成强制交付的 `setup.exe` 时使用 Inno Setup 7.0.2 x64。商业发布应按
  Inno Setup 官方许可要求购买许可证。

## 构建与测试

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

Release x64 构建和自包含发布：

```powershell
msbuild Windows\XDecode.Windows.sln /m /restore `
  /p:Configuration=Release /p:Platform=x64 `
  /p:VcpkgInstalledDir="$PWD\Windows\vcpkg_installed"

$publish = "$PWD\Windows\publish\win-x64"
dotnet publish Windows\src\XDecode.Windows\XDecode.Windows.csproj -c Release `
  -r win-x64 --self-contained true -o $publish `
  -p:Platform=x64 -p:WindowsPackageType=None `
  -p:WindowsAppSDKSelfContained=true `
  -p:VcpkgInstalledDir="$PWD\Windows\vcpkg_installed"
$explorerCommand = Get-ChildItem Windows -Recurse `
  -Filter XDecode.ExplorerCommand.dll | Where-Object FullName -Match '\\x64\\Release\\' `
  | Select-Object -First 1
Copy-Item $explorerCommand.FullName $publish
```

发布目录同时携带 .NET 10 和 Windows App SDK 运行时，目标机器无需预装这些运行时。
这比复用系统 WebView2 的 Tauri 应用更大，但避免了缺少运行时导致无法启动；Inno 直接对
发布目录做 solid LZMA2 压缩，不再先生成已压缩 MSIX 后二次封装。

## 生成 setup.exe

正式交付物是 `XDecode-Setup-x64.exe`。安装器以当前用户身份直接安装到
`%LOCALAPPDATA%\Programs\XDecode`，不请求管理员权限，也不导入测试证书。它负责注册：

- 开始菜单入口和标准卸载项。
- 当前用户开机启动。
- `.xlog`、`.mx`、`.logan`、`.zip` 的“打开方式”。
- 只转发普通文件的原生 Explorer Command。

在仓库外准备签名 `.pfx`。PFX 和密码只通过 CI Secret
`WINDOWS_SIGNING_PFX_BASE64`、`WINDOWS_SIGNING_PASSWORD` 注入，不得提交到仓库。
安装 Inno Setup 7.0.2 后执行：

```powershell
$env:WINDOWS_SIGNING_PASSWORD = "仅在当前终端设置的 PFX 密码"

& .\Windows\installer\build-setup.ps1 `
  -PublishDirectory $publish `
  -SigningPfxPath "C:\XDecode-Cert\XDecode-Signing.pfx" `
  -Version "1.0.0"
```

输出位于 `Windows\installer\Output\XDecode-Setup-x64.exe`。构建脚本会校验 x64
架构和版本，先签名主程序与 Explorer Command，再编译并签名安装器。

普通安装直接双击 `XDecode-Setup-x64.exe`。无交互安装无需管理员终端：

```powershell
.\XDecode-Setup-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

从旧 MSIX 版本升级时，安装器会先把设置、DPAPI 密钥、历史和 suppression 数据迁移到
`%LOCALAPPDATA%\LineShine\XDecode`，再移除旧包。新版覆盖安装保留该目录；明确卸载时删除
应用设置，但不删除用户日志、ZIP 或已经发布的输出。

CI 还会验证 Inno Setup 官方 release attestation 和发布者签名，安装生成的 setup，真实
启动已安装应用并等待主窗口和 10 秒存活，然后检查系统集成与卸载清理，最终上传
`XDecode-Windows-x64-setup` Artifact。

## 项目

- `src/XDecode.Core`：解码协议、限制、单文件和 ZIP 事务。
- `src/XDecode.Application`：规则、DPAPI 设置、历史、队列、监听和更新检查。
- `src/XDecode.Windows`：WinUI 3、托盘、通知、开机启动和单实例激活。
- `src/XDecode.ExplorerCommand`：只转发普通文件的原生 `IExplorerCommand`。
- `installer`：当前用户安装、旧 MSIX 数据迁移、签名和 `setup.exe` 构建。
- `packaging`：旧 MSIX 的清单与资源，仅保留为历史兼容参考，不参与发布构建。

ZIP 的 Windows 路径校验额外拒绝 UNC、盘符、ADS、设备名、非法字符、末尾空格或点、
符号链接和特殊条目。单文件完整发布后才永久删除源文件；ZIP 永远保留。

Windows 10/11 的手工安装与系统集成验收项见 [`ACCEPTANCE.md`](ACCEPTANCE.md)。
