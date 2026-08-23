#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ReceiptPath,

    [Parameter(Mandatory)]
    [string] $SourceRequestPath,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FileSha256 {
    param([string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-InvariantString {
    param($Value)
    if ($null -eq $Value) { return $null }
    [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-SanitizedUrl {
    param([string] $Url)
    $builder = [UriBuilder]::new([Uri]$Url)
    $builder.Query = ''
    $builder.Fragment = ''
    $builder.UserName = ''
    $builder.Password = ''
    $builder.Uri.AbsoluteUri.TrimEnd('?')
}

function Get-ArchiveFormat {
    param([string] $Path)
    $bytes = [byte[]]::new(4)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $read = $stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ($read -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and
        (($bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04) -or ($bytes[2] -eq 0x05 -and $bytes[3] -eq 0x06) -or ($bytes[2] -eq 0x07 -and $bytes[3] -eq 0x08))) {
        return 'zip'
    }
    'not-zip'
}

if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Source receipt does not exist.' }
if (-not (Test-Path -LiteralPath $SourceRequestPath -PathType Leaf)) { throw 'Source request does not exist.' }
$receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
$request = Get-Content -LiteralPath $SourceRequestPath -Raw | ConvertFrom-Json -AsHashtable
if ([int]$receipt.schemaVersion -ne 1) { throw 'Source receipt schemaVersion must be 1.' }
if ([int]$request.schemaVersion -ne 1) { throw 'Source request schemaVersion must be 1.' }
if ([string]$receipt.status -cne 'delivered') { throw 'Source receipt is not in delivered state.' }
foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName')) {
    if ((ConvertTo-InvariantString $receipt.sourceRequest[$field]) -cne (ConvertTo-InvariantString $request[$field])) {
        throw "Source receipt $field does not match the immutable source request."
    }
}
$sourceUri = [Uri]$receipt.sourceUrl
if (-not $sourceUri.IsAbsoluteUri -or $sourceUri.Scheme -cne 'https' -or $sourceUri.Query -or $sourceUri.Fragment -or -not [string]::IsNullOrWhiteSpace($sourceUri.UserInfo)) {
    throw 'Source receipt URL is not sanitized.'
}
$requestUri = [Uri](ConvertTo-InvariantString $request.pageUrl)
$expectedGameDomain = 'warhammer40kdarktide'
$expectedPagePath = "/$expectedGameDomain/mods/$(ConvertTo-InvariantString $request.modId)"
if ((ConvertTo-InvariantString $request.gameDomain) -cne $expectedGameDomain -or
    $requestUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
    $requestUri.AbsolutePath.TrimEnd('/') -cne $expectedPagePath) {
    throw 'Source request does not identify the official Nexus MOD page for warhammer40kdarktide.'
}
$requestedFileName = ConvertTo-InvariantString $request.fileName
if ([IO.Path]::GetFileName($requestedFileName) -cne $requestedFileName -or
    $requestedFileName.TrimEnd([char[]]' .') -cne $requestedFileName -or
    $requestedFileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw 'Source request fileName is not one safe single file name.'
}
if ([string]$receipt.sourceUrl -cne (Get-SanitizedUrl -Url (ConvertTo-InvariantString $request.pageUrl))) {
    throw 'Source receipt URL does not match the sanitized source request pageUrl.'
}
if ([string]$receipt.provider -notin @('api', 'browser')) { throw 'Source receipt provider is unsupported.' }
foreach ($timing in @('downloadMilliseconds', 'waitingMilliseconds', 'verifyMilliseconds', 'deliverMilliseconds')) {
    if (-not $receipt.timings.Contains($timing) -or [int64]$receipt.timings[$timing] -lt 0) { throw "Source receipt $timing is invalid." }
}
$deliveredPath = [IO.Path]::GetFullPath([string]$receipt.deliveredPath)
if (-not (Test-Path -LiteralPath $deliveredPath -PathType Leaf)) { throw 'Delivered source file is missing.' }
$item = Get-Item -LiteralPath $deliveredPath
if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Delivered source must be a regular file.' }
if ([int64]$item.Length -ne [int64]$receipt.size) { throw 'Delivered source size does not match the receipt.' }
$actualSha256 = Get-FileSha256 -Path $deliveredPath
if ($actualSha256 -cne [string]$receipt.sha256) { throw 'Delivered source SHA-256 does not match the receipt.' }
if ([string]$receipt.archiveFormat -cne 'zip' -or (Get-ArchiveFormat -Path $deliveredPath) -cne 'zip') { throw 'Delivered source is not a ZIP archive.' }
if ([IO.Path]::GetFileName($deliveredPath) -cne [string]$receipt.filename -or $receipt.filename -cne (ConvertTo-InvariantString $request.fileName)) {
    throw 'Delivered source filename does not match the receipt and request.'
}
if (-not [string]::IsNullOrWhiteSpace([string]$receipt.officialSha256)) {
    if ($receipt.officialHashPassed -ne $true -or $actualSha256 -cne [string]$receipt.officialSha256) {
        throw 'Delivered source does not match the recorded official SHA-256.'
    }
}
if (@($receipt.stableObservations).Count -ne 2 -or $receipt.stableObservations[0].size -ne $receipt.stableObservations[1].size -or
    $receipt.stableObservations[0].lastWriteTimeUtc -cne $receipt.stableObservations[1].lastWriteTimeUtc) {
    throw 'Source receipt does not contain two matching stability observations.'
}

$result = [ordered]@{
    result = 'passed'
    receiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    receiptSha256 = Get-FileSha256 -Path $ReceiptPath
    deliveredPath = $deliveredPath
    deliveredSha256 = $actualSha256
}
if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 10 -Compress }
