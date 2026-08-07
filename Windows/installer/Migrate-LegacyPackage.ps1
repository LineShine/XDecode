[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$package = Get-AppxPackage -Name LineShine.XDecode |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $package) {
    return
}

Get-Process -Name XDecode.Windows -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

$source = Join-Path $env:LOCALAPPDATA "Packages\$($package.PackageFamilyName)\LocalState"
if (Test-Path -LiteralPath $source -PathType Container) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    @(
        'settings.v1.json',
        'secrets.v1.json',
        'history.v1.json',
        'automatic-decode-suppressions.v1.json'
    ) | ForEach-Object {
        $sourcePath = Join-Path $source $_
        $destinationPath = Join-Path $Destination $_
        if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $destinationPath)) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
        }
    }
}

Remove-AppxPackage -Package $package.PackageFullName
