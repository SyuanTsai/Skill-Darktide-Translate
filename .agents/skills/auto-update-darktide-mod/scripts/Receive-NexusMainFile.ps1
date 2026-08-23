#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRequestPath,

    [Parameter(Mandatory)]
    [string] $IncomingDirectory,

    [Parameter(Mandatory)]
    [string] $DeliveryDirectory,

    [Parameter(Mandatory)]
    [ValidateSet('api', 'browser')]
    [string] $Provider,

    [string] $DownloadedFilePath,

    [Parameter(Mandatory)]
    [string] $ReceiptPath,

    [ValidateRange(0, 60000)]
    [int] $ObservationIntervalMilliseconds = 1000,

    [string] $ApiDownloadUriEnvironmentVariable = 'NEXUS_DOWNLOAD_URI',
    [string] $ApiKeyEnvironmentVariable = 'NEXUS_API_KEY',
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value
    )
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Write-Result {
    param([Parameter(Mandatory)] $Value)
    if ($PassThru) { $Value } else { $Value | ConvertTo-Json -Depth 20 -Compress }
}

function Assert-ContainedFilePath {
    param([Parameter(Mandatory)][string] $Candidate, [Parameter(Mandatory)][string] $Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if (-not $candidateFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Downloaded file escapes the isolated incoming directory.'
    }
    $candidateFull
}

function Assert-RegularDirectoryRoot {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
    $item = Get-Item -LiteralPath $full
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label must not be a reparse point." }
    $full
}

function ConvertTo-InvariantString {
    param($Value)
    if ($null -eq $Value) { return $null }
    [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Read-SourceRequest {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Source request does not exist.' }
    $request = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$request.schemaVersion -ne 1) { throw 'Source request schemaVersion must be 1.' }
    foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName', 'pageUrl')) {
        if (-not $request.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $request[$field]))) {
            throw "Source request requires a unique $field value."
        }
    }
    $pageUri = [Uri](ConvertTo-InvariantString $request.pageUrl)
    if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -cne 'https') { throw 'Source request pageUrl must be an absolute HTTPS URL.' }
    $expectedGameDomain = 'warhammer40kdarktide'
    $expectedPagePath = "/$expectedGameDomain/mods/$(ConvertTo-InvariantString $request.modId)"
    if ((ConvertTo-InvariantString $request.gameDomain) -cne $expectedGameDomain -or
        $pageUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
        $pageUri.AbsolutePath.TrimEnd('/') -cne $expectedPagePath) {
        throw 'Source request must identify the official Nexus MOD page for warhammer40kdarktide.'
    }
    $requestedFileName = ConvertTo-InvariantString $request.fileName
    if ([IO.Path]::GetFileName($requestedFileName) -cne $requestedFileName -or
        $requestedFileName.TrimEnd([char[]]' .') -cne $requestedFileName -or
        $requestedFileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Source request fileName must be one safe single file name.'
    }
    [ordered]@{
        schemaVersion = 1
        gameDomain = ConvertTo-InvariantString $request.gameDomain
        modId = ConvertTo-InvariantString $request.modId
        mainFileId = ConvertTo-InvariantString $request.mainFileId
        version = ConvertTo-InvariantString $request.version
        fileName = ConvertTo-InvariantString $request.fileName
        pageUrl = ConvertTo-InvariantString $request.pageUrl
        officialSha256 = if ($request.Contains('officialSha256')) { (ConvertTo-InvariantString $request.officialSha256).ToLowerInvariant() } else { $null }
    }
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
    $bytes = [byte[]]::new(8)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $read = $stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ($read -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and
        (($bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04) -or ($bytes[2] -eq 0x05 -and $bytes[3] -eq 0x06) -or ($bytes[2] -eq 0x07 -and $bytes[3] -eq 0x08))) {
        return 'zip'
    }
    if ($read -ge 7 -and $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x61 -and $bytes[2] -eq 0x72 -and
        $bytes[3] -eq 0x21 -and $bytes[4] -eq 0x1A -and $bytes[5] -eq 0x07 -and $bytes[6] -in @(0x00, 0x01)) {
        return 'rar'
    }
    if ($read -ge 6 -and $bytes[0] -eq 0x37 -and $bytes[1] -eq 0x7A -and $bytes[2] -eq 0xBC -and
        $bytes[3] -eq 0xAF -and $bytes[4] -eq 0x27 -and $bytes[5] -eq 0x1C) {
        return '7z'
    }
    'unknown'
}

function New-WaitingResult {
    param([string] $Status, [string] $Code, [string] $Message, [string] $ArchiveFormat, [string] $Path)
    [ordered]@{
        result = 'waiting'
        status = $Status
        waitingReason = [ordered]@{ code = $Code; message = $Message }
        archiveFormat = $ArchiveFormat
        retainedPath = $Path
    }
}

function Invoke-ApiDownload {
    param([Collections.IDictionary] $Request, [string] $IncomingRoot)
    $downloadUriValue = [Environment]::GetEnvironmentVariable($ApiDownloadUriEnvironmentVariable)
    if ([string]::IsNullOrWhiteSpace($downloadUriValue)) {
        return New-WaitingResult -Status 'waiting-system' -Code 'api_download_uri_unavailable' -Message 'The API provider did not return an ephemeral download URL.'
    }
    $downloadUri = [Uri]$downloadUriValue
    if (-not $downloadUri.IsAbsoluteUri -or $downloadUri.Scheme -cne 'https' -or
        ($downloadUri.Host -cne 'nexusmods.com' -and -not $downloadUri.Host.EndsWith('.nexusmods.com', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'API download URI must use HTTPS on a nexusmods.com host.'
    }
    $temporaryPath = Assert-ContainedFilePath -Candidate (Join-Path $IncomingRoot ($Request.fileName + '.part')) -Root $IncomingRoot
    $finalPath = Assert-ContainedFilePath -Candidate (Join-Path $IncomingRoot $Request.fileName) -Root $IncomingRoot
    if (Test-Path -LiteralPath $temporaryPath -or Test-Path -LiteralPath $finalPath) { throw 'API download destination already exists.' }
    $client = [Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Skill-Darktide-Translate/0.3.0')
    $apiKey = [Environment]::GetEnvironmentVariable($ApiKeyEnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) { $client.DefaultRequestHeaders.Add('apikey', $apiKey) }
    try {
        $response = $client.GetAsync($downloadUri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -eq 429) {
            return New-WaitingResult -Status 'waiting-system' -Code 'nexus_rate_limited' -Message 'Nexus rate limit requires a later retry.'
        }
        $response.EnsureSuccessStatusCode()
        $input = $response.Content.ReadAsStream()
        $output = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        [IO.File]::Move($temporaryPath, $finalPath)
        $finalPath
    }
    finally { $client.Dispose() }
}

$request = Read-SourceRequest -Path ([IO.Path]::GetFullPath($SourceRequestPath))
$requestedExtension = [IO.Path]::GetExtension([string]$request.fileName).ToLowerInvariant()
if ($requestedExtension -in @('.rar', '.7z') -or $requestedExtension -ne '.zip') {
    Write-Result -Value (New-WaitingResult -Status 'waiting-user' -Code 'unsupported_archive_format' -Message 'Only ZIP Main files are supported in Schema 15.' -ArchiveFormat $requestedExtension.TrimStart('.') -Path $null)
    return
}

$incomingFull = [IO.Path]::GetFullPath($IncomingDirectory)
if (-not (Split-Path -Leaf $incomingFull).StartsWith('.incoming-', [StringComparison]::Ordinal)) {
    throw 'Incoming directory must use the run-isolated .incoming-<run-id> name.'
}
$incomingFull = Assert-RegularDirectoryRoot -Path $incomingFull -Label 'Incoming directory'
$receiptParent = Assert-RegularDirectoryRoot -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ReceiptPath))) -Label 'Receipt directory'

$providerStart = [Diagnostics.Stopwatch]::StartNew()
$candidate = if ($Provider -eq 'api') {
    Invoke-ApiDownload -Request $request -IncomingRoot $incomingFull
}
else {
    if ([string]::IsNullOrWhiteSpace($DownloadedFilePath)) {
        Write-Result -Value (New-WaitingResult -Status 'waiting-user' -Code 'browser_download_required' -Message 'Use the existing signed-in browser session to download the requested Main file.' -ArchiveFormat $null -Path $null)
        return
    }
    Assert-ContainedFilePath -Candidate $DownloadedFilePath -Root $incomingFull
}
$providerStart.Stop()
if ($candidate -is [Collections.IDictionary]) {
    Write-Result -Value $candidate
    return
}

$candidateFull = [IO.Path]::GetFullPath([string]$candidate)
$candidateExtension = [IO.Path]::GetExtension($candidateFull).ToLowerInvariant()
if ($candidateExtension -in @('.part', '.crdownload')) {
    Write-Result -Value (New-WaitingResult -Status 'waiting-system' -Code 'download_incomplete' -Message 'The provider output is still a partial download.' -ArchiveFormat $null -Path $candidateFull)
    return
}
if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { throw 'Downloaded file does not exist.' }
$candidateItem = Get-Item -LiteralPath $candidateFull
if ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Downloaded file must be a regular file, not a reparse point.' }

$sampleOne = [ordered]@{ size = [int64]$candidateItem.Length; lastWriteTimeUtc = $candidateItem.LastWriteTimeUtc.ToString('o'); observedAt = Get-UtcTimestamp }
if ($ObservationIntervalMilliseconds -gt 0) { [Threading.Thread]::Sleep($ObservationIntervalMilliseconds) }
$candidateItem = Get-Item -LiteralPath $candidateFull
$sampleTwo = [ordered]@{ size = [int64]$candidateItem.Length; lastWriteTimeUtc = $candidateItem.LastWriteTimeUtc.ToString('o'); observedAt = Get-UtcTimestamp }
if ($sampleOne.size -ne $sampleTwo.size -or $sampleOne.lastWriteTimeUtc -cne $sampleTwo.lastWriteTimeUtc) {
    Write-Result -Value (New-WaitingResult -Status 'waiting-system' -Code 'download_not_stable' -Message 'The provider output changed between two observations.' -ArchiveFormat $null -Path $candidateFull)
    return
}
if ($sampleTwo.size -le 0) { throw 'Downloaded file is empty.' }

$verifyStart = [Diagnostics.Stopwatch]::StartNew()
$archiveFormat = Get-ArchiveFormat -Path $candidateFull
$sha256 = Get-FileSha256 -Path $candidateFull
$officialHashPassed = $null
if (-not [string]::IsNullOrWhiteSpace([string]$request.officialSha256)) {
    if ($request.officialSha256 -notmatch '^[0-9a-f]{64}$') { throw 'officialSha256 must contain 64 hexadecimal characters.' }
    $officialHashPassed = $sha256 -ceq $request.officialSha256
}
$verifyStart.Stop()
$receipt = [ordered]@{
    schemaVersion = 1
    sourceRequest = [ordered]@{
        gameDomain = $request.gameDomain
        modId = $request.modId
        mainFileId = $request.mainFileId
        version = $request.version
        fileName = $request.fileName
    }
    provider = $Provider
    sourceUrl = Get-SanitizedUrl -Url $request.pageUrl
    filename = [IO.Path]::GetFileName($candidateFull)
    size = $sampleTwo.size
    sha256 = $sha256
    archiveFormat = $archiveFormat
    officialSha256 = $request.officialSha256
    officialHashPassed = $officialHashPassed
    stableObservations = @($sampleOne, $sampleTwo)
    downloadedAt = Get-UtcTimestamp
    deliveredAt = $null
    deliveredPath = $null
    status = 'verified'
    timings = [ordered]@{
        downloadMilliseconds = $providerStart.ElapsedMilliseconds
        waitingMilliseconds = [int64]$ObservationIntervalMilliseconds
        verifyMilliseconds = $verifyStart.ElapsedMilliseconds
        deliverMilliseconds = 0
    }
}

if ($archiveFormat -ne 'zip') {
    $receipt.status = 'unsupported'
    Write-AtomicJson -Path $ReceiptPath -Value $receipt
    Write-Result -Value (New-WaitingResult -Status 'waiting-user' -Code 'unsupported_archive_format' -Message "Detected unsupported $archiveFormat archive bytes after download." -ArchiveFormat $archiveFormat -Path $candidateFull)
    return
}
if ($false -eq $officialHashPassed) {
    $receipt.status = 'rejected'
    Write-AtomicJson -Path $ReceiptPath -Value $receipt
    Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; waitingReason = [ordered]@{ code = 'source_hash_mismatch'; message = 'Downloaded SHA-256 does not match the official hash.' }; retainedPath = $candidateFull })
    return
}
if ([IO.Path]::GetFileName($candidateFull) -cne [string]$request.fileName) {
    $receipt.status = 'rejected'
    Write-AtomicJson -Path $ReceiptPath -Value $receipt
    Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; waitingReason = [ordered]@{ code = 'source_filename_mismatch'; message = 'Downloaded filename does not match the requested Main file.' }; retainedPath = $candidateFull })
    return
}

$deliveryStart = [Diagnostics.Stopwatch]::StartNew()
$deliveryFull = [IO.Path]::GetFullPath($DeliveryDirectory)
$deliveryFull = Assert-RegularDirectoryRoot -Path $deliveryFull -Label 'Delivery directory'
$deliveredPath = Assert-ContainedFilePath -Candidate (Join-Path $deliveryFull $request.fileName) -Root $deliveryFull
if (Test-Path -LiteralPath $deliveredPath) { throw 'Verified source delivery destination already exists.' }
Write-AtomicJson -Path $ReceiptPath -Value $receipt
[IO.File]::Move($candidateFull, $deliveredPath)
$deliveryStart.Stop()
$receipt.status = 'delivered'
$receipt.deliveredAt = Get-UtcTimestamp
$receipt.deliveredPath = $deliveredPath
$receipt.timings.deliverMilliseconds = $deliveryStart.ElapsedMilliseconds
Write-AtomicJson -Path $ReceiptPath -Value $receipt

Write-Result -Value ([ordered]@{
    result = 'passed'
    status = 'delivered'
    deliveredPath = $deliveredPath
    receiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    receiptSha256 = Get-FileSha256 -Path $ReceiptPath
    timings = $receipt.timings
})
