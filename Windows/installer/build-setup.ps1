[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MsixPath,
    [Parameter(Mandatory = $true)]
    [string]$CertificatePath,
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

Import-Module (Join-Path $PSScriptRoot 'MsixTools.psm1') -Force
$resolvedMsix = (Resolve-Path -LiteralPath $MsixPath).Path
$resolvedCertificate = (Resolve-Path -LiteralPath $CertificatePath).Path
$resolvedPfx = (Resolve-Path -LiteralPath $SigningPfxPath).Path

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $resolvedCertificate)
$signer = Get-XDecodeMsixSignerCertificate -Path $resolvedMsix
if ($signer.Thumbprint -ne $certificate.Thumbprint) {
    throw 'The MSIX signer does not match the supplied CER'
}
$identity = Get-XDecodeMsixIdentity -Path $resolvedMsix
if ($identity.Name -ne 'LineShine.XDecode' -or
    $identity.Publisher -ne $certificate.Subject -or
    $identity.ProcessorArchitecture -ne 'x64') {
    throw 'The input is not a signed XDecode x64 MSIX'
}

$pfx = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $resolvedPfx,
    $SigningPassword,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
if (-not $pfx.HasPrivateKey -or $pfx.Thumbprint -ne $certificate.Thumbprint) {
    throw 'The PFX private key does not match the MSIX signing certificate'
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

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$scriptPath = Join-Path $PSScriptRoot 'XDecode.iss'
& $InnoCompiler "/DSourceMsix=$resolvedMsix" "/DSourceCer=$resolvedCertificate" `
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
    throw 'The generated setup.exe signer does not match the MSIX signer'
}

Write-Output $setupPath
