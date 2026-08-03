#ifndef SourceMsix
  #error SourceMsix must point to the signed XDecode MSIX
#endif
#ifndef SourceCer
  #error SourceCer must point to the public signing certificate
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef OutputDir
  #define OutputDir SourcePath + "Output"
#endif

[Setup]
AppId=LineShine.XDecode.Setup
AppName=XDecode
AppVersion={#AppVersion}
AppVerName=XDecode {#AppVersion}
AppPublisher=LineShine
AppPublisherURL=https://github.com/LineShine/XDecode
AppSupportURL=https://github.com/LineShine/XDecode/issues
DefaultDirName={localappdata}\LineShine\XDecode.Setup
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.19045
OutputDir={#OutputDir}
OutputBaseFilename=XDecode-Setup-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=no
DisableDirPage=yes
DisableProgramGroupPage=yes
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
SetupLogging=yes
InfoBeforeFile={#SourcePath}\test-certificate-warning.zh-CN.txt
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=LineShine
VersionInfoDescription=XDecode Windows 安装程序
VersionInfoProductName=XDecode
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#SourceMsix}"; DestDir: "{tmp}"; DestName: "XDecode.msix"; Flags: ignoreversion deleteafterinstall
Source: "{#SourceCer}"; DestDir: "{tmp}"; DestName: "XDecode-signing.cer"; Flags: ignoreversion deleteafterinstall
Source: "{#SourcePath}\MsixTools.psm1"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall
Source: "{#SourcePath}\Install-XDecode.ps1"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall; AfterInstall: InstallPackage

[Code]
function InitializeSetup(): Boolean;
begin
  Result := True;
  if WizardSilent and
     (CompareText(ExpandConstant('{param:ACCEPTTESTCERT|0}'), '1') <> 0) then
  begin
    Log('Silent installation requires /ACCEPTTESTCERT=1');
    Result := False;
  end;
end;

procedure InstallPackage();
var
  PowerShellPath: String;
  Parameters: String;
  ResultCode: Integer;
begin
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{tmp}\Install-XDecode.ps1')) + ' -MsixPath ' +
    AddQuotes(ExpandConstant('{tmp}\XDecode.msix')) + ' -CertificatePath ' +
    AddQuotes(ExpandConstant('{tmp}\XDecode-signing.cer'));
  if not Exec(PowerShellPath, Parameters, '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) then
    RaiseException('无法启动 Windows 包安装程序。');
  if ResultCode <> 0 then
    RaiseException(Format('XDecode 安装失败，错误代码：%d。', [ResultCode]));
end;
