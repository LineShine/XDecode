#ifndef SourcePublishDir
  #error SourcePublishDir must point to the unpackaged self-contained publish directory
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
DefaultDirName={localappdata}\Programs\XDecode
DefaultGroupName=XDecode
UninstallDisplayIcon={app}\XDecode.Windows.exe
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.19045
OutputDir={#OutputDir}
OutputBaseFilename=XDecode-Setup-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dynamic
DisableWelcomePage=no
DisableDirPage=yes
DisableProgramGroupPage=yes
CloseApplications=force
CloseApplicationsFilter=XDecode.Windows.exe
RestartApplications=no
RestartIfNeededByRun=no
SetupLogging=yes
ChangesAssociations=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=LineShine
VersionInfoDescription=XDecode Windows 安装程序
VersionInfoProductName=XDecode
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
Source: "{#SourcePublishDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourcePath}\Migrate-LegacyPackage.ps1"; DestDir: "{tmp}"; Flags: ignoreversion deleteafterinstall

[Icons]
Name: "{group}\XDecode"; Filename: "{app}\XDecode.Windows.exe"; WorkingDir: "{app}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\XDecode.Windows.exe"; ValueType: string; ValueName: ""; ValueData: "{app}\XDecode.Windows.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "XDecode"; ValueData: """{app}\XDecode.Windows.exe"" --startup"; Flags: uninsdeletevalue; Check: ShouldInstallStartup

Root: HKCU; Subkey: "Software\Classes\Applications\XDecode.Windows.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "XDecode"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\XDecode.Windows.exe\shell\open"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Player"
Root: HKCU; Subkey: "Software\Classes\Applications\XDecode.Windows.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\XDecode.Windows.exe"" --open-with ""%1"""

Root: HKCU; Subkey: "Software\Classes\XDecode.Log"; ValueType: string; ValueName: ""; ValueData: "XDecode 日志"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\XDecode.Log\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\XDecode.Windows.exe,0"
Root: HKCU; Subkey: "Software\Classes\XDecode.Log\shell\open"; ValueType: string; ValueName: "MultiSelectModel"; ValueData: "Player"
Root: HKCU; Subkey: "Software\Classes\XDecode.Log\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\XDecode.Windows.exe"" --open-with ""%1"""
Root: HKCU; Subkey: "Software\Classes\.xlog\OpenWithProgids"; ValueType: string; ValueName: "XDecode.Log"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.mx\OpenWithProgids"; ValueType: string; ValueName: "XDecode.Log"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.logan\OpenWithProgids"; ValueType: string; ValueName: "XDecode.Log"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.zip\OpenWithProgids"; ValueType: string; ValueName: "XDecode.Log"; ValueData: ""; Flags: uninsdeletevalue

Root: HKCU; Subkey: "Software\Classes\CLSID\{{A9D140B0-2466-47AB-88F4-1A2D0C7BBE12}"; ValueType: string; ValueName: ""; ValueData: "XDecode Explorer Command"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\CLSID\{{A9D140B0-2466-47AB-88F4-1A2D0C7BBE12}\InprocServer32"; ValueType: string; ValueName: ""; ValueData: "{app}\XDecode.ExplorerCommand.dll"
Root: HKCU; Subkey: "Software\Classes\CLSID\{{A9D140B0-2466-47AB-88F4-1A2D0C7BBE12}\InprocServer32"; ValueType: string; ValueName: "ThreadingModel"; ValueData: "Apartment"
Root: HKCU; Subkey: "Software\Classes\*\shell\XDecodeDecrypt"; ValueType: string; ValueName: "MUIVerb"; ValueData: "使用 XDecode 解密"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\*\shell\XDecodeDecrypt"; ValueType: string; ValueName: "ExplorerCommandHandler"; ValueData: "{{A9D140B0-2466-47AB-88F4-1A2D0C7BBE12}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{tmp}\Migrate-LegacyPackage.ps1"" -Destination ""{localappdata}\LineShine\XDecode"""; StatusMsg: "正在迁移旧版本设置..."; Flags: runhidden waituntilterminated
Filename: "{app}\XDecode.Windows.exe"; Description: "启动 XDecode"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\LineShine\XDecode"

[Code]
var
  ExistingInstall: Boolean;
  StartupWasEnabled: Boolean;

function TakeVersionPart(var Value: String): Integer;
var
  Separator: Integer;
  Part: String;
begin
  Separator := Pos('.', Value);
  if Separator = 0 then
  begin
    Part := Value;
    Value := '';
  end
  else
  begin
    Part := Copy(Value, 1, Separator - 1);
    Delete(Value, 1, Separator);
  end;
  Result := StrToIntDef(Part, 0);
end;

function CompareVersions(LeftVersion, RightVersion: String): Integer;
var
  Index: Integer;
  LeftPart: Integer;
  RightPart: Integer;
begin
  Result := 0;
  for Index := 1 to 4 do
  begin
    LeftPart := TakeVersionPart(LeftVersion);
    RightPart := TakeVersionPart(RightVersion);
    if LeftPart > RightPart then
    begin
      Result := 1;
      Exit;
    end;
    if LeftPart < RightPart then
    begin
      Result := -1;
      Exit;
    end;
  end;
end;

function InitializeSetup(): Boolean;
var
  InstalledVersion: String;
begin
  ExistingInstall := RegKeyExists(
    HKCU,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\LineShine.XDecode.Setup_is1');
  StartupWasEnabled := RegValueExists(
    HKCU,
    'Software\Microsoft\Windows\CurrentVersion\Run',
    'XDecode');
  Result := True;
  if ExistingInstall and
     RegQueryStringValue(
       HKCU,
       'Software\Microsoft\Windows\CurrentVersion\Uninstall\LineShine.XDecode.Setup_is1',
       'DisplayVersion',
       InstalledVersion) and
     (CompareVersions(InstalledVersion, '{#AppVersion}') > 0) then
  begin
    SuppressibleMsgBox(
      '已安装的 XDecode 版本更新，不能用旧版本覆盖。',
      mbError,
      MB_OK,
      IDOK);
    Result := False;
  end;
end;

function ShouldInstallStartup(): Boolean;
begin
  Result := (not ExistingInstall) or StartupWasEnabled;
end;
