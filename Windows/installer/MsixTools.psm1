Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    Add-Type -AssemblyName System.Security.Cryptography.Pkcs -ErrorAction Stop
}
catch {
    Add-Type -AssemblyName System.Security
}

function Get-XDecodeMsixEntryBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$EntryName
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($null -eq $entry) {
            throw "MSIX is missing $EntryName"
        }
        $stream = $entry.Open()
        try {
            $memory = New-Object System.IO.MemoryStream
            try {
                $stream.CopyTo($memory)
                return ,$memory.ToArray()
            }
            finally {
                $memory.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-XDecodeMsixSignerCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $signature = Get-XDecodeMsixEntryBytes -Path $Path -EntryName 'AppxSignature.p7x'
    if ($signature.Length -le 4 -or
        [System.Text.Encoding]::ASCII.GetString($signature, 0, 4) -ne 'PKCX') {
        throw 'MSIX signature has an invalid PKCX header'
    }

    $payload = New-Object byte[] ($signature.Length - 4)
    [System.Array]::Copy($signature, 4, $payload, 0, $payload.Length)
    $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
    $cms.Decode($payload)
    $cms.CheckSignature($true)
    if ($cms.SignerInfos.Count -ne 1 -or $null -eq $cms.SignerInfos[0].Certificate) {
        throw 'MSIX must contain exactly one signing certificate'
    }
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $cms.SignerInfos[0].Certificate.RawData)
}

function Get-XDecodeMsixIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $manifestBytes = Get-XDecodeMsixEntryBytes -Path $Path -EntryName 'AppxManifest.xml'
    $manifest = [System.Xml.XmlDocument]::new()
    $manifest.XmlResolver = $null
    $manifestStream = [System.IO.MemoryStream]::new($manifestBytes, $false)
    try {
        $manifest.Load($manifestStream)
    }
    finally {
        $manifestStream.Dispose()
    }
    $identity = $manifest.Package.Identity
    if ($null -eq $identity) {
        throw 'MSIX manifest does not contain an Identity element'
    }
    return [pscustomobject]@{
        Name = [string]$identity.Name
        Publisher = [string]$identity.Publisher
        Version = [version]$identity.Version
        ProcessorArchitecture = [string]$identity.ProcessorArchitecture
    }
}

Export-ModuleMember -Function Get-XDecodeMsixSignerCertificate, Get-XDecodeMsixIdentity
