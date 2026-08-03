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

## 生成 setup.exe

正式交付物是 `XDecode-Setup-x64.exe`。它内含签名 MSIX 和对应公钥 CER，应用仍由
Windows 包管理器安装，因此文件关联、StartupTask、通知和 Explorer Command 不会因
EXE 封装而降级。

先生成已签名 MSIX，并在仓库外准备签名所用的 `.pfx` 及从同一证书导出的 `.cer`。
安装 Inno Setup 7.0.2 后执行：

```powershell
$env:WINDOWS_SIGNING_PASSWORD = "仅在当前终端设置的 PFX 密码"

& .\Windows\installer\build-setup.ps1 `
  -MsixPath "Windows\packaging\AppPackages\...\XDecode.msix" `
  -CertificatePath "C:\XDecode-Cert\XDecode-Test.cer" `
  -SigningPfxPath "C:\XDecode-Cert\XDecode-Test.pfx" `
  -Version "1.0.0"
```

输出位于 `Windows\installer\Output\XDecode-Setup-x64.exe`。构建脚本会拒绝以下输入：

- MSIX、CER 和 PFX 不是同一签名身份。
- 包名不是 `LineShine.XDecode`，Publisher 与证书不一致，或架构不是 x64。
- `setup.exe` 未能使用同一 PFX 完成 Authenticode 签名。

普通安装直接双击 `XDecode-Setup-x64.exe`，并在标准 UAC 提示中允许管理员权限，以便
Windows 在本机 `TrustedPeople` 中临时信任内部测试证书。无交互部署必须从管理员终端
启动，并显式确认内部测试证书：

```powershell
.\XDecode-Setup-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ACCEPTTESTCERT=1
```

安装器只在部署期间向本机 `TrustedPeople` 临时加入此前未受信任的内置证书，并在成功
或失败后移除；用户原本已经信任的同一证书不会被删除。升级和卸载仍使用 Windows
“已安装的应用”中的 XDecode 包记录，安装器本身不创建第二个卸载项。

CI 需要设置 `WINDOWS_SIGNING_PFX_BASE64`、`WINDOWS_SIGNING_PASSWORD`。商业使用
Inno Setup 时再设置 `INNO_SETUP_LICENSE_KEY`。Windows workflow 会验证 Inno Setup 官方
release attestation 和发布者签名，生成、签名并真实安装 `setup.exe`，最终上传
`XDecode-Windows-x64-setup` Artifact。

## 项目

- `src/XDecode.Core`：解码协议、限制、单文件和 ZIP 事务。
- `src/XDecode.Application`：规则、DPAPI 设置、历史、队列、监听和更新检查。
- `src/XDecode.Windows`：WinUI 3、托盘、通知、启动任务和单实例激活。
- `src/XDecode.ExplorerCommand`：只转发普通文件的原生 `IExplorerCommand`。
- `packaging`：文件关联、COM、StartupTask 和自包含 MSIX。
- `installer`：签名 MSIX 校验、临时证书信任和单文件 `setup.exe` 引导安装器。

ZIP 的 Windows 路径校验额外拒绝 UNC、盘符、ADS、设备名、非法字符、末尾空格或点、
符号链接和特殊条目。单文件完整发布后才永久删除源文件；ZIP 永远保留。

Windows 10/11 的手工安装与系统集成验收项见 [`ACCEPTANCE.md`](ACCEPTANCE.md)。
