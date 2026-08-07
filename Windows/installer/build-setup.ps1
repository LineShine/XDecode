[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDirectory,
    [string]$Version = '1.0.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'Output'),
    [string]$InnoCompiler
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must contain exactly three numeric components, for example 1.0.0'
}

$resolvedPublish = (Resolve-Path -LiteralPath $PublishDirectory).Path
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

foreach ($target in @($appPath, $explorerCommandPath)) {
    if ((Get-AuthenticodeSignature -LiteralPath $target).Status -ne 'NotSigned') {
        throw "$target must be unsigned"
    }
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
if ((Get-AuthenticodeSignature -LiteralPath $setupPath).Status -ne 'NotSigned') {
    throw 'The generated setup.exe must be unsigned'
}

Write-Output $setupPath
