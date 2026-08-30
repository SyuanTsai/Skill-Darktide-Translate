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

    [string] $RunRoot,

    [ValidateRange(0, 60000)]
    [int] $ObservationIntervalMilliseconds = 1000,

    [string] $ApiDownloadUriEnvironmentVariable = 'NEXUS_DOWNLOAD_URI',
    [string] $ApiKeyEnvironmentVariable = 'NEXUS_API_KEY',
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-JsonToken {
    param([AllowNull()][Newtonsoft.Json.Linq.JToken] $Token, [switch] $AsHashtable)
    if ($null -eq $Token -or $Token.Type -in @(
        [Newtonsoft.Json.Linq.JTokenType]::Null,
        [Newtonsoft.Json.Linq.JTokenType]::Undefined
    )) { return $null }
    if ($Token -is [Newtonsoft.Json.Linq.JObject]) {
        $properties = [ordered]@{}
        foreach ($property in $Token.Properties()) {
            $properties[[string]$property.Name] = ConvertFrom-JsonToken -Token $property.Value -AsHashtable:$AsHashtable
        }
        if ($AsHashtable) { return $properties }
        return [pscustomobject]$properties
    }
    if ($Token -is [Newtonsoft.Json.Linq.JArray]) {
        $items = [object[]]::new($Token.Count)
        for ($index = 0; $index -lt $Token.Count; $index++) {
            $items[$index] = ConvertFrom-JsonToken -Token $Token[$index] -AsHashtable:$AsHashtable
        }
        Write-Output -NoEnumerate $items
        return
    }
    ([Newtonsoft.Json.Linq.JValue]$Token).Value
}

function ConvertFrom-Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $InputObject,
        [switch] $AsHashtable
    )
    process {
        $parameters = @{ InputObject = $InputObject }
        if ($AsHashtable) { $parameters.AsHashtable = $true }
        $nativeCommand = Get-Command -Name 'Microsoft.PowerShell.Utility\ConvertFrom-Json'
        if ($nativeCommand.Parameters.ContainsKey('DateKind')) {
            $parameters.DateKind = 'String'
            Microsoft.PowerShell.Utility\ConvertFrom-Json @parameters
            return
        }
        $settings = [Newtonsoft.Json.JsonSerializerSettings]::new()
        $settings.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $token = [Newtonsoft.Json.JsonConvert]::DeserializeObject($InputObject, $settings)
        ConvertFrom-JsonToken -Token $token -AsHashtable:$AsHashtable
    }
}

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Invoke-Heartbeat {
    if ($HeartbeatAction) { $null = & $HeartbeatAction }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    Invoke-Heartbeat
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
            Invoke-Heartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

function Copy-StreamWithHeartbeat {
    param([IO.Stream] $Source, [IO.Stream] $Destination)
    Invoke-Heartbeat
    $buffer = [byte[]]::new(1MB)
    while (($readCount = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $Destination.Write($buffer, 0, $readCount)
        Invoke-Heartbeat
    }
}

function Wait-TaskWithHeartbeat {
    param([Parameter(Mandatory)][Threading.Tasks.Task] $Task)
    Invoke-Heartbeat
    while (-not $Task.IsCompleted) {
        [Threading.Thread]::Sleep(1000)
        Invoke-Heartbeat
    }
    $Task.GetAwaiter().GetResult()
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value
    )
    Invoke-Heartbeat
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

function Assert-NoReparsePath {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Label, [switch] $AllowMissingLeaf)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the isolated source run root."
    }
    $relative = [IO.Path]::GetRelativePath($rootFull, $pathFull)
    $components = if ($relative -eq '.') { @() } else { @($relative -split '[\\/]') }
    $current = $rootFull
    $paths = @($rootFull)
    foreach ($component in $components) { $current = Join-Path $current $component; $paths += $current }
    for ($index = 0; $index -lt $paths.Count; $index++) {
        if (-not (Test-Path -LiteralPath $paths[$index])) {
            if ($AllowMissingLeaf -and $index -eq ($paths.Count - 1)) { continue }
            throw "$Label path component is missing."
        }
        if ((Get-Item -LiteralPath $paths[$index]).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label path contains a symlink or reparse point."
        }
    }
}

function Assert-RegularDirectoryRoot {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Label, [Parameter(Mandatory)][string] $RunRoot)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Assert-NoReparsePath -Path (Split-Path -Parent $full) -Root $RunRoot -Label "$Label parent"
        New-Item -ItemType Directory -Path $full | Out-Null
    }
    Assert-NoReparsePath -Path $full -Root $RunRoot -Label $Label
    $full
}

function ConvertTo-InvariantString {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Read-SourceRequest {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Source request does not exist.' }
    $request = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$request.schemaVersion -notin @(1, 2)) { throw 'Source request schemaVersion must be 1 or 2.' }
    foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName', 'pageUrl')) {
        if (-not $request.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $request[$field]))) {
            throw "Source request requires a unique $field value."
        }
    }
    if ([int]$request.schemaVersion -eq 2) {
        foreach ($field in @('pageVersion', 'pageUpdatedAt', 'mainFileUploadedAtUtc')) {
            if (-not $request.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $request[$field]))) {
                throw "Schema 2 source request requires immutable Nexus metadata field $field."
            }
        }
        foreach ($timestampField in @('pageUpdatedAt', 'mainFileUploadedAtUtc')) {
            $timestamp = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParseExact(
                (ConvertTo-InvariantString $request[$timestampField]), 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp
            )) { throw "Schema 2 source request $timestampField must be an ISO-8601 round-trip timestamp." }
        }
    }
    $pageUri = [Uri](ConvertTo-InvariantString $request.pageUrl)
    if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -cne 'https') { throw 'Source request pageUrl must be an absolute HTTPS URL.' }
    if (-not [string]::IsNullOrEmpty($pageUri.UserInfo) -or -not [string]::IsNullOrEmpty($pageUri.Query) -or
        -not [string]::IsNullOrEmpty($pageUri.Fragment) -or -not $pageUri.IsDefaultPort) {
        throw 'Source request pageUrl must be a canonical page URL without user-info, query, fragment, or a custom port.'
    }
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
    if ($requestedFileName -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
        throw 'Source request fileName uses a reserved Windows device name.'
    }
    [ordered]@{
        schemaVersion = [int]$request.schemaVersion
        gameDomain = ConvertTo-InvariantString $request.gameDomain
        modId = ConvertTo-InvariantString $request.modId
        mainFileId = ConvertTo-InvariantString $request.mainFileId
        version = ConvertTo-InvariantString $request.version
        fileName = ConvertTo-InvariantString $request.fileName
        pageUrl = ConvertTo-InvariantString $request.pageUrl
        pageVersion = if ($request.Contains('pageVersion')) { ConvertTo-InvariantString $request.pageVersion } else { $null }
        pageUpdatedAt = if ($request.Contains('pageUpdatedAt')) { ConvertTo-InvariantString $request.pageUpdatedAt } else { $null }
        mainFileUploadedAtUtc = if ($request.Contains('mainFileUploadedAtUtc')) { ConvertTo-InvariantString $request.mainFileUploadedAtUtc } else { $null }
        officialSha256 = if ($request.Contains('officialSha256') -and
            -not [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $request.officialSha256))) {
            (ConvertTo-InvariantString $request.officialSha256).ToLowerInvariant()
        } else { $null }
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

function Assert-NexusDownloadUri {
    param([Uri] $Uri, [string] $Label = 'API download URI')
    if (-not $Uri -or -not $Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or
        ($Uri.Host -cne 'nexusmods.com' -and -not $Uri.Host.EndsWith('.nexusmods.com', [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label must use HTTPS on a nexusmods.com host."
    }
    $Uri
}

function Get-ArchiveEvidence {
    param([string] $Path)
    $bytes = [byte[]]::new(8)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $size = $stream.Length
        $read = $stream.Read($bytes, 0, $bytes.Length)
        $stream.Position = 0
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
            Invoke-Heartbeat
        }
        $sha256 = [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
        $format = if ($read -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and
            (($bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04) -or ($bytes[2] -eq 0x05 -and $bytes[3] -eq 0x06) -or ($bytes[2] -eq 0x07 -and $bytes[3] -eq 0x08))) {
            'zip'
        }
        elseif ($read -ge 7 -and $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x61 -and $bytes[2] -eq 0x72 -and
            $bytes[3] -eq 0x21 -and $bytes[4] -eq 0x1A -and $bytes[5] -eq 0x07 -and $bytes[6] -in @(0x00, 0x01)) {
            'rar'
        }
        elseif ($read -ge 6 -and $bytes[0] -eq 0x37 -and $bytes[1] -eq 0x7A -and $bytes[2] -eq 0xBC -and
            $bytes[3] -eq 0xAF -and $bytes[4] -eq 0x27 -and $bytes[5] -eq 0x1C) {
            '7z'
        }
        else { 'unknown' }
        [ordered]@{ size = [int64]$size; sha256 = $sha256; archiveFormat = $format; stream = $stream }
    }
    catch {
        $stream.Dispose()
        throw
    }
    finally {
        $hasher.Dispose()
    }
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

function Move-ApiPartialToRetainedEvidence {
    param([string] $PartialPath, [string] $IncomingRoot)
    if (-not (Test-Path -LiteralPath $PartialPath)) { return $null }
    $item = Get-Item -LiteralPath $PartialPath
    if (-not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $retainedName = '.retained-partial-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [guid]::NewGuid().ToString('N') + '-' + $item.Name
        $retainedPath = Assert-ContainedFilePath -Candidate (Join-Path $IncomingRoot $retainedName) -Root $IncomingRoot
        Invoke-Heartbeat
        [IO.File]::Move($item.FullName, $retainedPath)
        return $retainedPath
    }
    throw 'API partial download must be a regular file, not a directory or reparse point.'
}

function Invoke-ApiDownload {
    param([Collections.IDictionary] $Request, [string] $IncomingRoot)
    $temporaryPath = Assert-ContainedFilePath -Candidate (Join-Path $IncomingRoot ($Request.fileName + '.part')) -Root $IncomingRoot
    $finalPath = Assert-ContainedFilePath -Candidate (Join-Path $IncomingRoot $Request.fileName) -Root $IncomingRoot
    $retainedPartialPath = Move-ApiPartialToRetainedEvidence -PartialPath $temporaryPath -IncomingRoot $IncomingRoot
    if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
        return $finalPath
    }
    $downloadUriValue = [Environment]::GetEnvironmentVariable($ApiDownloadUriEnvironmentVariable)
    if ([string]::IsNullOrWhiteSpace($downloadUriValue)) {
        return New-WaitingResult -Status 'waiting-system' -Code 'api_download_uri_unavailable' -Message 'The API provider did not return an ephemeral download URL.' -Path $retainedPartialPath
    }
    $downloadUri = Assert-NexusDownloadUri -Uri ([Uri]$downloadUriValue)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler, $true)
    $response = $null
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Skill-Darktide-Translate/0.3.7')
    $apiKey = [Environment]::GetEnvironmentVariable($ApiKeyEnvironmentVariable)
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) { $client.DefaultRequestHeaders.Add('apikey', $apiKey) }
    try {
        $currentUri = $downloadUri
        for ($redirectCount = 0; $redirectCount -le 10; $redirectCount++) {
            if ($response) { $response.Dispose(); $response = $null }
            $responseTask = $client.GetAsync($currentUri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
            $response = Wait-TaskWithHeartbeat -Task $responseTask
            if ([int]$response.StatusCode -notin @(301, 302, 303, 307, 308)) { break }
            if ($redirectCount -eq 10) { throw 'API download exceeded the ten-redirect safety limit.' }
            $location = $response.Headers.Location
            if (-not $location) { throw 'API download redirect is missing its Location header.' }
            $nextUri = if ($location.IsAbsoluteUri) { $location } else { [Uri]::new($currentUri, $location) }
            $currentUri = Assert-NexusDownloadUri -Uri $nextUri -Label 'API download redirect URI'
        }
        if ([int]$response.StatusCode -eq 429) {
            return New-WaitingResult -Status 'waiting-system' -Code 'nexus_rate_limited' -Message 'Nexus rate limit requires a later retry.' -Path $retainedPartialPath
        }
        if ([int]$response.StatusCode -in @(401, 403)) {
            return New-WaitingResult -Status 'waiting-user' -Code 'nexus_permission_required' -Message 'Nexus login or download permission requires user action.' -Path $retainedPartialPath
        }
        $response.EnsureSuccessStatusCode()
        $responseStream = Wait-TaskWithHeartbeat -Task ($response.Content.ReadAsStreamAsync())
        $outputStream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { Copy-StreamWithHeartbeat -Source $responseStream -Destination $outputStream } finally { $outputStream.Dispose(); $responseStream.Dispose() }
        Invoke-Heartbeat
        [IO.File]::Move($temporaryPath, $finalPath)
        $finalPath
    }
    catch [Net.Http.HttpRequestException] {
        $retainedPartialPath = Move-ApiPartialToRetainedEvidence -PartialPath $temporaryPath -IncomingRoot $IncomingRoot
        return New-WaitingResult -Status 'waiting-system' -Code 'api_download_interrupted' -Message 'The API download did not complete and its partial bytes were retained for evidence.' -Path $retainedPartialPath
    }
    catch [Threading.Tasks.TaskCanceledException] {
        $retainedPartialPath = Move-ApiPartialToRetainedEvidence -PartialPath $temporaryPath -IncomingRoot $IncomingRoot
        return New-WaitingResult -Status 'waiting-system' -Code 'api_download_interrupted' -Message 'The API download did not complete and its partial bytes were retained for evidence.' -Path $retainedPartialPath
    }
    catch [IO.IOException] {
        $retainedPartialPath = Move-ApiPartialToRetainedEvidence -PartialPath $temporaryPath -IncomingRoot $IncomingRoot
        return New-WaitingResult -Status 'waiting-system' -Code 'api_download_interrupted' -Message 'The API download did not complete and its partial bytes were retained for evidence.' -Path $retainedPartialPath
    }
    finally { if ($response) { $response.Dispose() }; $client.Dispose() }
}

$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
$receiptParentPath = Split-Path -Parent $receiptFull
$sourceRunRoot = if (-not [string]::IsNullOrWhiteSpace($RunRoot)) { [IO.Path]::GetFullPath($RunRoot) }
    elseif ((Split-Path -Leaf $receiptParentPath) -ceq 'review-artifacts') { Split-Path -Parent $receiptParentPath }
    else { $receiptParentPath }
if (-not (Test-Path -LiteralPath $sourceRunRoot -PathType Container)) { throw 'Receipt run root does not exist.' }
Assert-NoReparsePath -Path $sourceRunRoot -Root $sourceRunRoot -Label 'Source run root'
$requestFull = [IO.Path]::GetFullPath($SourceRequestPath)
Assert-NoReparsePath -Path $requestFull -Root $sourceRunRoot -Label 'Source request'
$request = Read-SourceRequest -Path $requestFull
$requestedExtension = [IO.Path]::GetExtension([string]$request.fileName).ToLowerInvariant()
if ($requestedExtension -ne '.zip') {
    Write-Result -Value (New-WaitingResult -Status 'waiting-user' -Code 'unsupported_archive_format' -Message 'Only ZIP Main files are supported in Schema 15.' -ArchiveFormat $requestedExtension.TrimStart('.') -Path $null)
    return
}

$incomingFull = [IO.Path]::GetFullPath($IncomingDirectory)
if (-not (Split-Path -Leaf $incomingFull).StartsWith('.incoming-', [StringComparison]::Ordinal)) {
    throw 'Incoming directory must use the run-isolated .incoming-<run-id> name.'
}
$incomingFull = Assert-RegularDirectoryRoot -Path $incomingFull -Label 'Incoming directory' -RunRoot $sourceRunRoot
$receiptParent = Assert-RegularDirectoryRoot -Path $receiptParentPath -Label 'Receipt directory' -RunRoot $sourceRunRoot
Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt' -AllowMissingLeaf

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
Assert-NoReparsePath -Path $candidateFull -Root $sourceRunRoot -Label 'Downloaded file'
$candidateExtension = [IO.Path]::GetExtension($candidateFull).ToLowerInvariant()
if ($candidateExtension -in @('.part', '.crdownload')) {
    Write-Result -Value (New-WaitingResult -Status 'waiting-system' -Code 'download_incomplete' -Message 'The provider output is still a partial download.' -ArchiveFormat $null -Path $candidateFull)
    return
}
if (-not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { throw 'Downloaded file does not exist.' }
$candidateItem = Get-Item -LiteralPath $candidateFull
if ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Downloaded file must be a regular file, not a reparse point.' }

$sampleOne = [ordered]@{ size = [int64]$candidateItem.Length; lastWriteTimeUtc = $candidateItem.LastWriteTimeUtc.ToString('o'); observedAt = Get-UtcTimestamp }
if ($ObservationIntervalMilliseconds -gt 0) {
    $remainingMilliseconds = $ObservationIntervalMilliseconds
    while ($remainingMilliseconds -gt 0) {
        $slice = [Math]::Min(1000, $remainingMilliseconds)
        [Threading.Thread]::Sleep($slice)
        $remainingMilliseconds -= $slice
        Invoke-Heartbeat
    }
}
Assert-NoReparsePath -Path $candidateFull -Root $sourceRunRoot -Label 'Downloaded file'
$candidateItem = Get-Item -LiteralPath $candidateFull
$sampleTwo = [ordered]@{ size = [int64]$candidateItem.Length; lastWriteTimeUtc = $candidateItem.LastWriteTimeUtc.ToString('o'); observedAt = Get-UtcTimestamp }
if ($sampleOne.size -ne $sampleTwo.size -or $sampleOne.lastWriteTimeUtc -cne $sampleTwo.lastWriteTimeUtc) {
    Write-Result -Value (New-WaitingResult -Status 'waiting-system' -Code 'download_not_stable' -Message 'The provider output changed between two observations.' -ArchiveFormat $null -Path $candidateFull)
    return
}
if ($sampleTwo.size -le 0) { throw 'Downloaded file is empty.' }

$verifyStart = [Diagnostics.Stopwatch]::StartNew()
Assert-NoReparsePath -Path $candidateFull -Root $sourceRunRoot -Label 'Downloaded file'
$archiveEvidence = Get-ArchiveEvidence -Path $candidateFull
$temporaryDelivery = $null
$deleteCandidateAfterDelivery = $false
try {
    if ([int64]$archiveEvidence.size -ne [int64]$sampleTwo.size) {
        $verifyStart.Stop()
        Write-Result -Value (New-WaitingResult -Status 'waiting-system' -Code 'download_not_stable' -Message 'The provider output changed while its immutable evidence was computed.' -ArchiveFormat ([string]$archiveEvidence.archiveFormat) -Path $candidateFull)
        return
    }
    $archiveFormat = [string]$archiveEvidence.archiveFormat
    $sha256 = [string]$archiveEvidence.sha256
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
            pageUrl = $request.pageUrl
            pageVersion = $request.pageVersion
            pageUpdatedAt = $request.pageUpdatedAt
            mainFileUploadedAtUtc = $request.mainFileUploadedAtUtc
        }
        provider = $Provider
        sourceUrl = Get-SanitizedUrl -Url $request.pageUrl
        filename = [IO.Path]::GetFileName($candidateFull)
        size = $archiveEvidence.size
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
        Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt' -AllowMissingLeaf
        Write-AtomicJson -Path $ReceiptPath -Value $receipt
        Write-Result -Value (New-WaitingResult -Status 'waiting-user' -Code 'unsupported_archive_format' -Message "Detected unsupported $archiveFormat archive bytes after download." -ArchiveFormat $archiveFormat -Path $candidateFull)
        return
    }
    if ($false -eq $officialHashPassed) {
        $receipt.status = 'rejected'
        Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt' -AllowMissingLeaf
        Write-AtomicJson -Path $ReceiptPath -Value $receipt
        Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; waitingReason = [ordered]@{ code = 'source_hash_mismatch'; message = 'Downloaded SHA-256 does not match the official hash.' }; retainedPath = $candidateFull })
        return
    }
    if ([IO.Path]::GetFileName($candidateFull) -cne [string]$request.fileName) {
        $receipt.status = 'rejected'
        Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt' -AllowMissingLeaf
        Write-AtomicJson -Path $ReceiptPath -Value $receipt
        Write-Result -Value ([ordered]@{ result = 'blocked'; status = 'blocked'; waitingReason = [ordered]@{ code = 'source_filename_mismatch'; message = 'Downloaded filename does not match the requested Main file.' }; retainedPath = $candidateFull })
        return
    }

    $deliveryStart = [Diagnostics.Stopwatch]::StartNew()
    $deliveryFull = [IO.Path]::GetFullPath($DeliveryDirectory)
    $deliveryFull = Assert-RegularDirectoryRoot -Path $deliveryFull -Label 'Delivery directory' -RunRoot $sourceRunRoot
    $deliveredPath = Assert-ContainedFilePath -Candidate (Join-Path $deliveryFull $request.fileName) -Root $deliveryFull
    if (Test-Path -LiteralPath $deliveredPath) { throw 'Verified source delivery destination already exists.' }
    Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt' -AllowMissingLeaf
    Write-AtomicJson -Path $ReceiptPath -Value $receipt
    Assert-NoReparsePath -Path $candidateFull -Root $sourceRunRoot -Label 'Downloaded file'
    Assert-NoReparsePath -Path $deliveredPath -Root $sourceRunRoot -Label 'Delivered source' -AllowMissingLeaf
    Invoke-Heartbeat
    $temporaryDelivery = Assert-ContainedFilePath -Candidate (Join-Path $deliveryFull ('.delivery-' + [guid]::NewGuid().ToString('N') + '.tmp')) -Root $deliveryFull
    $destination = [IO.File]::Open($temporaryDelivery, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archiveEvidence.stream.Position = 0
        Copy-StreamWithHeartbeat -Source $archiveEvidence.stream -Destination $destination
        $destination.Flush($true)
    }
    finally { $destination.Dispose() }
    [IO.File]::Move($temporaryDelivery, $deliveredPath)
    $temporaryDelivery = $null
    $deleteCandidateAfterDelivery = $true
    $deliveryStart.Stop()
    $receipt.status = 'delivered'
    $receipt.deliveredAt = Get-UtcTimestamp
    $receipt.deliveredPath = $deliveredPath
    $receipt.timings.deliverMilliseconds = $deliveryStart.ElapsedMilliseconds
    Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt'
    Write-AtomicJson -Path $ReceiptPath -Value $receipt

    Write-Result -Value ([ordered]@{
        result = 'passed'
        status = 'delivered'
        deliveredPath = $deliveredPath
        receiptPath = [IO.Path]::GetFullPath($ReceiptPath)
        receiptSha256 = Get-FileSha256 -Path $ReceiptPath
        timings = $receipt.timings
    })
}
finally {
    if ($archiveEvidence.stream) { $archiveEvidence.stream.Dispose() }
    if ($temporaryDelivery -and (Test-Path -LiteralPath $temporaryDelivery -PathType Leaf)) {
        [IO.File]::Delete($temporaryDelivery)
    }
    if ($deleteCandidateAfterDelivery -and (Test-Path -LiteralPath $candidateFull -PathType Leaf)) {
        Assert-NoReparsePath -Path $candidateFull -Root $sourceRunRoot -Label 'Delivered source input cleanup'
        [IO.File]::Delete($candidateFull)
    }
}
