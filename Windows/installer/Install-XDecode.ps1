[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MsixPath,
    [Parameter(Mandatory = $true)]
    [string]$CertificatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'MsixTools.psm1') -Force

function Test-TrustedCertificate {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        return $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Certificate.Thumbprint,
            $false).Count -gt 0
    }
    finally {
        $store.Close()
    }
}

function Add-TrustedCertificate {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $store.Add($Certificate)
    }
    finally {
        $store.Close()
    }
}

function Remove-TrustedCertificate {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
        [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPeople,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $matches = $store.Certificates.Find(
            [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
            $Certificate.Thumbprint,
            $false)
        foreach ($match in $matches) {
            $store.Remove($match)
        }
    }
    finally {
        $store.Close()
    }
}

try {
    if (-not (Test-Path -LiteralPath $MsixPath -PathType Leaf)) {
        throw "MSIX was not found: $MsixPath"
    }
    if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw "Signing certificate was not found: $CertificatePath"
    }

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        (Resolve-Path -LiteralPath $CertificatePath).Path)
    if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -lt (Get-Date)) {
        throw 'The bundled signing certificate is not currently valid'
    }

    $resolvedMsix = (Resolve-Path -LiteralPath $MsixPath).Path
    $signer = Get-XDecodeMsixSignerCertificate -Path $resolvedMsix
    if ($signer.Thumbprint -ne $certificate.Thumbprint) {
        throw 'The MSIX signer does not match the bundled certificate'
    }

    $identity = Get-XDecodeMsixIdentity -Path $resolvedMsix
    if ($identity.Name -ne 'LineShine.XDecode' -or
        $identity.Publisher -ne $certificate.Subject -or
        $identity.ProcessorArchitecture -ne 'x64') {
        throw 'The MSIX identity, publisher, or architecture is not an XDecode x64 package'
    }

    $installed = Get-AppxPackage -Name $identity.Name |
        Where-Object { $_.Publisher -eq $identity.Publisher } |
        Select-Object -First 1
    if ($null -ne $installed -and [version]$installed.Version -gt $identity.Version) {
        throw "A newer XDecode version is already installed: $($installed.Version)"
    }
    if ($null -ne $installed -and [version]$installed.Version -eq $identity.Version) {
        exit 0
    }

    $certificateWasTrusted = Test-TrustedCertificate -Certificate $certificate
    if (-not $certificateWasTrusted) {
        Add-TrustedCertificate -Certificate $certificate
    }
    try {
        Add-AppxPackage -Path $resolvedMsix -ForceApplicationShutdown
        $deployed = Get-AppxPackage -Name $identity.Name |
            Where-Object { $_.Publisher -eq $identity.Publisher } |
            Select-Object -First 1
        if ($null -eq $deployed -or [version]$deployed.Version -ne $identity.Version) {
            throw 'Windows did not register the expected XDecode package version'
        }
    }
    finally {
        if (-not $certificateWasTrusted) {
            Remove-TrustedCertificate -Certificate $certificate
        }
    }
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
