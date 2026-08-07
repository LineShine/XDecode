[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDirectory,
    [Parameter(Mandatory = $true)]
    [string]$SigningPfxPath,
    [string]$SigningPassword = $env:WINDOWS_SIGNING_PASSWORD,
    [string]$Version = '1.0.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'Output'),
    [string]$InnoCompiler,
    [string]$SignTool
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must contain exactly three numeric components, for example 1.0.0'
}
if ([string]::IsNullOrWhiteSpace($SigningPassword)) {
    throw 'WINDOWS_SIGNING_PASSWORD or -SigningPassword is required'
}

$resolvedPublish = (Resolve-Path -LiteralPath $PublishDirectory).Path
$resolvedPfx = (Resolve-Path -LiteralPath $SigningPfxPath).Path
$appPath = Join-Path $resolvedPublish 'XDecode.Windows.exe'
$explorerCommandPath = Join-Path $resolvedPublish 'XDecode.ExplorerCommand.dll'
if (-not (Test-Path -LiteralPath $appPath -PathType Leaf)) {
    throw 'The publish directory does not contain XDecode.Windows.exe'
}
if (-not (Test-Path -LiteralPath $explorerCommandPath -PathType Leaf)) {
    throw 'The publish directory does not contain XDecode.ExplorerCommand.dll'
}

function Get-PeMachine([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "$Path is not a PE file" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "$Path has an invalid PE header" }
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

if ((Get-PeMachine -Path $appPath) -ne 0x8664 -or
    (Get-PeMachine -Path $explorerCommandPath) -ne 0x8664) {
    throw 'XDecode publish output must contain x64 PE binaries'
}
$expectedFileVersion = [version]"$Version.0"
$actualFileVersion = [version](Get-Item -LiteralPath $appPath).VersionInfo.FileVersion
if ($actualFileVersion -ne $expectedFileVersion) {
    throw "XDecode.Windows.exe version $actualFileVersion does not match $expectedFileVersion"
}

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $resolvedPfx,
    $SigningPassword,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
if (-not $certificate.HasPrivateKey) {
    throw 'The supplied PFX does not contain a private key'
}

if ([string]::IsNullOrWhiteSpace($InnoCompiler)) {
    $compilerCandidates = @(
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe')
    )
    $InnoCompiler = $compilerCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($InnoCompiler) -or
    -not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
    throw 'Inno Setup 7 ISCC.exe was not found'
}

if ([string]::IsNullOrWhiteSpace($SignTool)) {
    $kitsDirectory = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $SignTool = Get-ChildItem $kitsDirectory -Recurse -Filter signtool.exe |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -ExpandProperty FullName -First 1
}
if ([string]::IsNullOrWhiteSpace($SignTool) -or
    -not (Test-Path -LiteralPath $SignTool -PathType Leaf)) {
    throw 'Windows SDK x64 signtool.exe was not found'
}

foreach ($target in @($appPath, $explorerCommandPath)) {
    & $SignTool sign /fd SHA256 /f $resolvedPfx /p $SigningPassword $target
    if ($LASTEXITCODE -ne 0) {
        throw "Authenticode signing failed for $target with exit code $LASTEXITCODE"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $target
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
        throw "The signer for $target does not match the supplied PFX"
    }
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$scriptPath = Join-Path $PSScriptRoot 'XDecode.iss'
& $InnoCompiler "/DSourcePublishDir=$resolvedPublish" `
    "/DAppVersion=$Version" "/DOutputDir=$resolvedOutput" $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

$setupPath = Join-Path $resolvedOutput 'XDecode-Setup-x64.exe'
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw 'Inno Setup did not produce XDecode-Setup-x64.exe'
}
& $SignTool sign /fd SHA256 /f $resolvedPfx /p $SigningPassword $setupPath
if ($LASTEXITCODE -ne 0) {
    throw "setup.exe signing failed with exit code $LASTEXITCODE"
}

$setupSignature = Get-AuthenticodeSignature -LiteralPath $setupPath
if ($null -eq $setupSignature.SignerCertificate -or
    $setupSignature.SignerCertificate.Thumbprint -ne $certificate.Thumbprint) {
    throw 'The generated setup.exe signer does not match the supplied PFX'
}

Write-Output $setupPath
