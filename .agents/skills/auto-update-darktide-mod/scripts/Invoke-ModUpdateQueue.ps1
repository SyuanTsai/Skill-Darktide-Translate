#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot,
    [Parameter(Mandatory)][string] $QueuePath,
    [string] $SkillSourcePinPath,
    [int] $ThrottleLimit = 4,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ThrottleLimit -lt 1 -or $ThrottleLimit -gt 4) { throw 'ThrottleLimit must be between 1 and 4.' }
$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$queueFull = [IO.Path]::GetFullPath($QueuePath)
if (-not (Test-Path -LiteralPath $repository -PathType Container)) { throw 'RepositoryRoot does not exist.' }
if (-not (Test-Path -LiteralPath $queueFull -PathType Leaf)) { throw 'QueuePath does not exist.' }
$queue = Get-Content -LiteralPath $queueFull -Raw | ConvertFrom-Json -AsHashtable
if ([int]$queue.schemaVersion -ne 1) { throw 'Queue schemaVersion must be 1.' }
$items = @($queue.items)
if ($items.Count -eq 0) { throw 'Queue must contain at least one source acquisition item.' }
$identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in $items) {
    foreach ($field in @('modDirectory', 'sourceRequestPath', 'provider')) {
        if (-not $item.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$item[$field])) { throw "Queue item requires $field." }
    }
    if ([string]$item.provider -notin @('api', 'browser')) { throw 'Queue provider must be api or browser.' }
    if (-not $identities.Add(([string]$item.modDirectory).Trim())) { throw 'Queue contains a duplicate canonical MOD identity.' }
}
if ([string]::IsNullOrWhiteSpace($SkillSourcePinPath) -or -not (Test-Path -LiteralPath $SkillSourcePinPath -PathType Leaf)) {
    throw 'Queue execution requires -SkillSourcePinPath for the immutable darktide-translate source tuple.'
}
$skillSourcePinFull = [IO.Path]::GetFullPath($SkillSourcePinPath)

$runner = Join-Path $PSScriptRoot 'mod-update.ps1'
$results = @(
    $items | ForEach-Object -Parallel {
        $item = $_
        $arguments = @{
            RepositoryRoot = $using:repository
            ModDirectory = [string]$item.modDirectory
            SourceRequestPath = [IO.Path]::GetFullPath([string]$item.sourceRequestPath)
            SkillSourcePinPath = $using:skillSourcePinFull
            Provider = [string]$item.provider
            PassThru = $true
        }
        if ($item.Contains('runId') -and -not [string]::IsNullOrWhiteSpace([string]$item.runId)) { $arguments.RunId = [string]$item.runId }
        if ($item.Contains('downloadedFilePath') -and -not [string]::IsNullOrWhiteSpace([string]$item.downloadedFilePath)) { $arguments.DownloadedFilePath = [IO.Path]::GetFullPath([string]$item.downloadedFilePath) }
        if ($item.Contains('observationIntervalMilliseconds')) { $arguments.ObservationIntervalMilliseconds = [int]$item.observationIntervalMilliseconds }
        try {
            & $using:runner acquire-source @arguments
        }
        catch {
            [ordered]@{
                result = 'failed'
                status = 'failed'
                stage = 'acquire-source'
                modDirectory = [string]$item.modDirectory
                runId = if ($arguments.ContainsKey('RunId')) { [string]$arguments.RunId } else { $null }
                error = [ordered]@{
                    code = 'worker_failed'
                    message = 'Source acquisition worker failed before producing a structured result.'
                    type = $_.Exception.GetType().FullName
                }
            }
        }
    } -ThrottleLimit $ThrottleLimit
)
$output = [ordered]@{
    result = if (@($results | Where-Object { $_.status -notin @('delivered', 'waiting-user', 'waiting-system') }).Count -eq 0) { 'passed' } else { 'failed' }
    throttleLimit = $ThrottleLimit
    itemCount = $items.Count
    results = $results
}
if ($PassThru) { $output } else { $output | ConvertTo-Json -Depth 30 -Compress }
