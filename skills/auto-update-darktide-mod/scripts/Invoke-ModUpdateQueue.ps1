# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
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
$coordinationModule = Join-Path $PSScriptRoot 'SharedCoordinationLock.psm1'
Import-Module -Name $coordinationModule -Force -ErrorAction Stop

function Read-QueueTextWithHeartbeat {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][Collections.IDictionary] $Lease)
    $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $readCount)
            Update-SharedCoordinationLease -Lease $Lease
        }
        [Text.UTF8Encoding]::new($false, $true).GetString($memory.ToArray())
    }
    finally { $memory.Dispose(); $source.Dispose() }
}

$queueRunId = [guid]::NewGuid().ToString()
$queueReceiptRoot = Join-Path $repository "AI Auto Update/In Progress/.queue-coordination/$queueRunId"
$sourceInventoryLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' `
    -RunId $queueRunId -ReceiptRoot $queueReceiptRoot
try {
    $queue = Read-QueueTextWithHeartbeat -Path $queueFull -Lease $sourceInventoryLease | ConvertFrom-Json -AsHashtable
    if ([int]$queue.schemaVersion -ne 1) { throw 'Queue schemaVersion must be 1.' }
    $rawItems = @($queue.items)
    if ($rawItems.Count -eq 0) { throw 'Queue must contain at least one source acquisition item.' }
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $items = @(
        foreach ($item in $rawItems) {
            Update-SharedCoordinationLease -Lease $sourceInventoryLease
            foreach ($field in @('modDirectory', 'sourceRequestPath', 'provider')) {
                if (-not $item.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$item[$field])) { throw "Queue item requires $field." }
            }
            if ([string]$item.provider -notin @('api', 'browser')) { throw 'Queue provider must be api or browser.' }
            $canonicalMod = ([string]$item.modDirectory).Trim()
            if (-not $identities.Add($canonicalMod)) { throw 'Queue contains a duplicate canonical MOD identity.' }
            [ordered]@{
                modDirectory = $canonicalMod
                sourceRequestPath = [IO.Path]::GetFullPath([string]$item.sourceRequestPath)
                provider = [string]$item.provider
                runId = if ($item.Contains('runId') -and -not [string]::IsNullOrWhiteSpace([string]$item.runId)) {
                    [guid]::Parse([string]$item.runId).ToString()
                } else { $null }
                downloadedFilePath = if ($item.Contains('downloadedFilePath') -and -not [string]::IsNullOrWhiteSpace([string]$item.downloadedFilePath)) {
                    [IO.Path]::GetFullPath([string]$item.downloadedFilePath)
                } else { $null }
                observationIntervalMilliseconds = if ($item.Contains('observationIntervalMilliseconds')) {
                    [int]$item.observationIntervalMilliseconds
                } else { $null }
            }
        }
    )
}
finally {
    $sourceInventoryReceipt = Exit-SharedCoordinationLease -Lease $sourceInventoryLease
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
            SourceRequestPath = [string]$item.sourceRequestPath
            SkillSourcePinPath = $using:skillSourcePinFull
            Provider = [string]$item.provider
            PassThru = $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.runId)) { $arguments.RunId = [string]$item.runId }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.downloadedFilePath)) { $arguments.DownloadedFilePath = [string]$item.downloadedFilePath }
        if ($null -ne $item.observationIntervalMilliseconds) { $arguments.ObservationIntervalMilliseconds = [int]$item.observationIntervalMilliseconds }
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
    coordinationReceipt = $sourceInventoryReceipt
    results = $results
}
if ($PassThru) { $output } else { $output | ConvertTo-Json -Depth 30 -Compress }
