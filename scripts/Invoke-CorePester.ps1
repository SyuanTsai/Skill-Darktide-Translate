# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $CandidateAuthorityAdapterRunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$integrityModulePath = Join-Path $PSScriptRoot 'CorePesterIntegrity.psm1'
Import-Module -Name $integrityModulePath -Force -ErrorAction Stop
$closureLockPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config/pester-6.2.0-closure.lock.json'))
$closureLockRecord = Read-CorePesterClosureLock -LiteralPath $closureLockPath
$verifiedPowerShellExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$verifiedPesterModuleRoot = Get-CorePesterRuntimeModuleRoot -ExecutablePath $verifiedPowerShellExecutable
$verifiedPesterManifest = Join-Path $verifiedPesterModuleRoot ([string]$closureLockRecord.Value.runtime.manifestRelativePath)
$moduleCandidates = @(Get-Module -ListAvailable -Name Pester | ForEach-Object {
    [pscustomobject]@{ Version = $_.Version; Path = $_.Path }
})
$candidateCheck = Test-CorePesterModuleCandidates -ExpectedManifestPath $verifiedPesterManifest -Candidates $moduleCandidates
if (-not $candidateCheck.IsValid) { throw ('Core Pester module candidate check failed: ' + (@($candidateCheck.Errors) -join '; ')) }
$preImportClosure = Test-CorePesterClosure -ModuleRoot $verifiedPesterModuleRoot -Lock $closureLockRecord.Value
if (-not $preImportClosure.IsValid) { throw ('Core Pester runtime closure check failed before import: ' + (@($preImportClosure.Errors) -join '; ')) }
$expectedLoadedPesterPath = Get-CorePesterExpectedLoadedModulePath -ManifestPath $verifiedPesterManifest -ModuleRoot $verifiedPesterModuleRoot -Lock $closureLockRecord.Value
$alreadyLoadedPester = @(Get-Module -Name Pester)
if ($alreadyLoadedPester.Count -ne 0) { throw 'Core Pester refuses to reuse an already-loaded Pester module.' }
Import-Module -Name $verifiedPesterManifest -ErrorAction Stop
$loadedPester = @(Get-Module -Name Pester)
$loadedPesterCheck = Test-CorePesterLoadedModuleIdentity -Modules $loadedPester -ExpectedVersion ([string]$closureLockRecord.Value.source.version) -ExpectedPath $expectedLoadedPesterPath -ExpectedModuleBase $verifiedPesterModuleRoot
if (-not $loadedPesterCheck.IsValid) { throw ('Core Pester loaded-module identity failed: ' + (@($loadedPesterCheck.Errors) -join '; ')) }
$postImportClosure = Test-CorePesterClosure -ModuleRoot $verifiedPesterModuleRoot -Lock $closureLockRecord.Value
if (-not $postImportClosure.IsValid -or $postImportClosure.ClosureSha256 -cne $preImportClosure.ClosureSha256) {
    throw ('Core Pester runtime closure changed during import: ' + (@($postImportClosure.Errors) -join '; '))
}

function Get-VerifiedCoreAuthoritySnapshotPath {
    param([Parameter(Mandatory = $true)][string] $OuterAdapterRunId)

    if ($OuterAdapterRunId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Core Pester requires the canonical outer adapter run identity.'
    }
    $coreRunId = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_CORE_RUN_ID', 'Process')
    $checkId = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_CORE_CHECK_ID', 'Process')
    if ($coreRunId -cnotmatch '^[0-9a-f]{32}$' -or $checkId -cne 'repository-pester') {
        throw 'Core Pester requires the trusted repository-pester run identity.'
    }
    $candidateSnapshot = [IO.Path]::GetFullPath((Get-Location).Path)
    if ([IO.Path]::GetFileName($candidateSnapshot) -cne 'candidate') {
        throw 'Core Pester working directory is not the immutable candidate snapshot.'
    }
    $runRoot = Split-Path -Parent $candidateSnapshot
    if ([IO.Path]::GetFileName($runRoot) -cne $coreRunId) {
        throw 'Core Pester candidate snapshot does not match the trusted run identity.'
    }
    $runsRoot = Split-Path -Parent $runRoot
    if ([IO.Path]::GetFileName($runsRoot) -cne 'runs') {
        throw 'Core Pester candidate snapshot is outside the canonical runs directory.'
    }
    $coreArtifactsRoot = Split-Path -Parent $runsRoot
    $adapterParent = Split-Path -Parent $coreArtifactsRoot
    $adapterRoot = [IO.Path]::GetFullPath((Join-Path $adapterParent ".core-v2-adapter-$OuterAdapterRunId"))
    if (-not (Test-Path -LiteralPath (Join-Path $adapterRoot 'standard-core-adapter-v2.json') -PathType Leaf)) {
        throw 'Core Pester outer adapter identity does not select the run-owned adapter snapshot.'
    }
    $authorityRoot = [IO.Path]::GetFullPath((Join-Path $adapterRoot 'authority'))
    if (-not (Test-Path -LiteralPath $authorityRoot -PathType Container)) {
        throw 'Core Pester run-owned authority snapshot is missing.'
    }
    $cursor = $authorityRoot
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Core Pester run-owned authority snapshot contains a reparse ancestor.'
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
    return $authorityRoot
}

$verifiedAuthoritySnapshotRoot = Get-VerifiedCoreAuthoritySnapshotPath -OuterAdapterRunId $CandidateAuthorityAdapterRunId
$previousCandidateAuthorityRoot = [Environment]::GetEnvironmentVariable('SYP154_CANDIDATE_AUTHORITY_ROOT', 'Process')
$testRoot = Join-Path ([IO.Path]::GetFullPath((Get-Location).Path)) 'tests'
if (-not (Test-Path -LiteralPath $testRoot -PathType Container)) {
    throw "Canonical Pester test root is missing: $testRoot"
}
$candidateSnapshotRoot = [IO.Path]::GetFullPath((Get-Location).Path)
Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $candidateSnapshotRoot `
    -ReleasePath ([Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH', 'Process')) `
    -BootstrapCommand ([Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_BOOTSTRAP_COMMAND', 'Process')) `
    -VerifiedPowerShellExecutable $verifiedPowerShellExecutable
$candidateSnapshotBefore = Get-CorePesterTreeSnapshot -Root $candidateSnapshotRoot
if (-not $candidateSnapshotBefore.IsValid) { throw ('Core Pester candidate snapshot could not be bound: ' + (@($candidateSnapshotBefore.Errors) -join '; ')) }
$previousErrorActionPreference = $ErrorActionPreference
$progressCharacters = 0
$progressLimit = 300000
$completedCases = 0
$activeCaseStarts = 0
$progressCapped = $false
$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path = $testRoot
$pesterConfig.Run.PassThru = $true
$pesterConfig.Output.Verbosity = 'Detailed'
$pesterConfig.Debug.ShowStartMarkers = $true
# Repository tests do not use Pester's registry drive. Keep validation independent
# of per-user registry permissions and avoid test-run registry writes.
$pesterConfig.TestRegistry.Enabled = $false
$requestedPesterRunPath = [IO.Path]::GetFullPath($testRoot)
$configuredPathOption = $pesterConfig.Run.Path
$configuredPathValue = $configuredPathOption.PSObject.Properties['Value']
if ($null -ne $configuredPathValue) {
    $configuredPaths = @($configuredPathValue.Value)
    if ($configuredPaths.Count -ne 1 -or
        [IO.Path]::GetFullPath([string]$configuredPaths[0]) -cne $requestedPesterRunPath) {
        throw 'Core Pester must use the exact unfiltered full tests tree.'
    }
}
try {
    # Repository tests exercise non-zero native children; let Pester evaluate their assertions.
    # Keep the machine report on stdout and bounded live test progress on stderr.
    [Environment]::SetEnvironmentVariable('SYP154_CANDIDATE_AUTHORITY_ROOT', $verifiedAuthoritySnapshotRoot, 'Process')
    $ErrorActionPreference = 'Continue'
    $result = Invoke-Pester -Configuration $pesterConfig 3>$null 6>&1 |
        ForEach-Object {
            if ($_ -is [Management.Automation.InformationRecord]) {
                foreach ($rawLine in @(([string]$_.MessageData) -split '\r?\n')) {
                    $progressEvent = ConvertFrom-CorePesterProgressLine -Line ([string]$rawLine) -ActiveCaseStarts $activeCaseStarts
                    if (-not $progressEvent.IsRecognized) { continue }
                    $line = [string]$progressEvent.Line
                    $phase = [string]$progressEvent.Phase
                    $activeCaseStarts = [int]$progressEvent.ActiveCaseStarts
                    $completedCases += [int]$progressEvent.CompletedDelta
                    if ($line.Length -gt 300) { $line = $line.Substring(0, 300) + '[truncated]' }
                    $entry = "Pester progress utc=$([DateTimeOffset]::UtcNow.ToString('o')) completed=$completedCases phase=$phase $line"
                    if ($progressCharacters + $entry.Length -le $progressLimit) {
                        [Console]::Error.WriteLine($entry)
                        $progressCharacters += $entry.Length
                    }
                    elseif (-not $progressCapped) {
                        [Console]::Error.WriteLine('Pester live progress cap reached.')
                        $progressCapped = $true
                    }
                }
            }
            else { $_ }
        }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    [Environment]::SetEnvironmentVariable('SYP154_CANDIDATE_AUTHORITY_ROOT', $previousCandidateAuthorityRoot, 'Process')
}
if ($null -eq $result) { throw 'Pester did not return a result object.' }
$postRunClosure = Test-CorePesterClosure -ModuleRoot $verifiedPesterModuleRoot -Lock $closureLockRecord.Value
if (-not $postRunClosure.IsValid -or $postRunClosure.ClosureSha256 -cne $preImportClosure.ClosureSha256) {
    foreach ($closureError in @($postRunClosure.Errors)) { [Console]::Error.WriteLine("Pester runtime closure error: $closureError") }
    [Console]::Error.WriteLine('Core Pester runtime closure changed while tests were running.')
    exit 1
}
$candidateSnapshotAfter = Get-CorePesterTreeSnapshot -Root $candidateSnapshotRoot
if (-not $candidateSnapshotAfter.IsValid -or $candidateSnapshotAfter.Sha256 -cne $candidateSnapshotBefore.Sha256) {
    foreach ($snapshotError in @($candidateSnapshotAfter.Errors)) { [Console]::Error.WriteLine("Candidate snapshot error: $snapshotError") }
    [Console]::Error.WriteLine('Core Pester candidate snapshot changed while tests were running.')
    exit 1
}

function Get-CorePesterItems {
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string] $Context)

    $items = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $Value) {
        foreach ($item in $Value) {
            if ($null -eq $item) { throw "Pester $Context contains a null item." }
            $items.Add($item)
        }
    }
    return ,$items
}

function New-CorePesterCaseInventoryRow {
    param(
        [Parameter(Mandatory)][object] $Case,
        [Parameter(Mandatory)][string] $TestRoot,
        [Parameter(Mandatory)][string] $Context
    )

    $expandedPath = ''
    $status = ''
    $relativePath = ''
    $sourceStartOffset = -1
    $sourceStartLine = 0
    $identity = ''
    $identityError = $null
    try {
        $expandedPath = [string]$Case.ExpandedPath
        $status = [string]$Case.Result
        if ([string]::IsNullOrWhiteSpace($expandedPath)) { throw 'the expanded path is empty.' }
        $scriptBlockProperty = $Case.PSObject.Properties['ScriptBlock']
        if ($null -eq $scriptBlockProperty -or $null -eq $scriptBlockProperty.Value -or
            $null -eq $scriptBlockProperty.Value.Ast -or $null -eq $scriptBlockProperty.Value.Ast.Extent) {
            throw 'the Pester case has no source AST extent.'
        }
        $extent = $scriptBlockProperty.Value.Ast.Extent
        $sourcePath = [IO.Path]::GetFullPath([string]$extent.File)
        $rootPrefix = $TestRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $sourcePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'the Pester case source file is outside the complete tests tree.'
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw 'the Pester case source file no longer exists.'
        }
        $relativePath = [IO.Path]::GetRelativePath($TestRoot, $sourcePath).Replace('\', '/')
        $sourceStartOffset = [int]$extent.StartOffset
        if ($sourceStartOffset -lt 0) { throw 'the Pester case source offset is invalid.' }
        $sourceStartLine = [int]$extent.StartLineNumber
        if ($sourceStartLine -le 0 -and $null -ne $Case.PSObject.Properties['StartLine']) {
            $sourceStartLine = [int]$Case.StartLine
        }
        if ($sourceStartLine -le 0) { throw 'the Pester case source line is invalid.' }
        $identity = Get-CorePesterCaseIdentity -RelativeSourceFile $relativePath -StartOffset $sourceStartOffset -ExpandedPath $expandedPath
    }
    catch {
        $identityError = "${Context}: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        identity = $identity
        sourceFile = $relativePath
        sourceStartOffset = $sourceStartOffset
        sourceStartLine = $sourceStartLine
        expandedPath = $expandedPath
        result = $status
        identityError = $identityError
    }
}

$caseInventoryErrors = [System.Collections.Generic.List[string]]::new()
$discoveryCases = [System.Collections.Generic.List[object]]::new()
$executionCases = [System.Collections.Generic.List[object]]::new()
$caseInventoryComplete = $false
$caseInventoryLedgerWritten = $false
$caseInventoryLedgerHash = $null
$caseInventoryLedgerPath = $null
$caseInventoryRunPath = $requestedPesterRunPath
$caseInventoryTestRoot = [IO.Path]::GetFullPath($testRoot)

try {
    $discoveredItems = Get-CorePesterItems -Value $result.Tests -Context 'discovered case inventory'
    foreach ($case in $discoveredItems) {
        $row = New-CorePesterCaseInventoryRow -Case $case -TestRoot $caseInventoryTestRoot -Context 'discovered case'
        $discoveryCases.Add($row)
        if (-not [string]::IsNullOrEmpty($row.identityError)) { $caseInventoryErrors.Add($row.identityError) }
    }

    $executionBuckets = @(
        [pscustomobject]@{ property = 'Passed'; status = 'Passed' }
        [pscustomobject]@{ property = 'Failed'; status = 'Failed' }
        [pscustomobject]@{ property = 'Skipped'; status = 'Skipped' }
        [pscustomobject]@{ property = 'Inconclusive'; status = 'Inconclusive' }
        [pscustomobject]@{ property = 'NotRun'; status = 'NotRun' }
    )
    foreach ($bucket in $executionBuckets) {
        $itemsProperty = $result.PSObject.Properties[[string]$bucket.property]
        if ($null -eq $itemsProperty) {
            $caseInventoryErrors.Add("Pester result is missing the $($bucket.property) execution collection.")
            continue
        }
        $bucketItems = Get-CorePesterItems -Value $itemsProperty.Value -Context "$($bucket.property) execution collection"
        foreach ($case in $bucketItems) {
            $row = New-CorePesterCaseInventoryRow -Case $case -TestRoot $caseInventoryTestRoot -Context "$($bucket.property) execution case"
            if ($row.result -cne [string]$bucket.status) {
                $caseInventoryErrors.Add("Pester $($bucket.property) collection contains result '$($row.result)'.")
            }
            $executionCases.Add($row)
            if (-not [string]::IsNullOrEmpty($row.identityError)) { $caseInventoryErrors.Add($row.identityError) }
        }
    }
}
catch {
    $caseInventoryErrors.Add("Pester case inventory collection failed: $($_.Exception.Message)")
}

$casePartitionCheck = Test-CorePesterCaseIdentityPartition -DiscoveryCases @($discoveryCases.ToArray()) -ExecutionCases @($executionCases.ToArray())
foreach ($partitionError in @($casePartitionCheck.Errors)) { $caseInventoryErrors.Add($partitionError) }

$total = [int]$result.TotalCount
$reportedCaseCounts = [ordered]@{}
foreach ($bucket in $executionBuckets) {
    $countPropertyName = switch ([string]$bucket.property) {
        'Passed' { 'PassedCount' }
        'Failed' { 'FailedCount' }
        'Skipped' { 'SkippedCount' }
        'Inconclusive' { 'InconclusiveCount' }
        'NotRun' { 'NotRunCount' }
    }
    $countProperty = $result.PSObject.Properties[$countPropertyName]
    $actualCount = if ($null -eq $countProperty) { -1 } else { [int]$countProperty.Value }
    $itemsProperty = $result.PSObject.Properties[[string]$bucket.property]
    $items = if ($null -eq $itemsProperty) { [System.Collections.Generic.List[object]]::new() } else { Get-CorePesterItems -Value $itemsProperty.Value -Context "$($bucket.property) execution collection" }
    $reportedCaseCounts[[string]$bucket.property] = $actualCount
    if ($actualCount -lt 0 -or $actualCount -ne $items.Count) {
        $caseInventoryErrors.Add("Pester $($bucket.property) count does not match its complete execution collection.")
    }
}

$containerItems = Get-CorePesterItems -Value $result.Containers -Context 'container inventory'
$containerCaseTotal = 0
$expectedTestFileInventory = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$containerFileInventory = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$discoveredCaseFileInventory = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
try {
    $candidateTestFiles = @(Get-ChildItem -LiteralPath $caseInventoryTestRoot -Recurse -File -Filter '*.Tests.ps1' -ErrorAction Stop)
    foreach ($testFile in $candidateTestFiles) {
        $fullPath = [IO.Path]::GetFullPath($testFile.FullName)
        $relativePath = [IO.Path]::GetRelativePath($caseInventoryTestRoot, $fullPath).Replace('\', '/')
        $fileKey = $relativePath.ToUpperInvariant()
        if ($expectedTestFileInventory.ContainsKey($fileKey)) {
            $caseInventoryErrors.Add("Candidate test file inventory contains an ambiguous path: $relativePath")
        }
        else { $expectedTestFileInventory.Add($fileKey, $relativePath) }
    }
    if ($expectedTestFileInventory.Count -eq 0) { $caseInventoryErrors.Add('Candidate tests tree contains no *.Tests.ps1 files.') }
}
catch {
    $caseInventoryErrors.Add("Candidate complete test-file inventory failed: $($_.Exception.Message)")
}

foreach ($container in $containerItems) {
    $containerNameProperty = $container.PSObject.Properties['Name']
    if ($null -eq $containerNameProperty -or [string]::IsNullOrWhiteSpace([string]$containerNameProperty.Value)) {
        $caseInventoryErrors.Add('A Pester container is missing its source file path.')
        continue
    }
    try {
        $containerFullPath = [IO.Path]::GetFullPath([string]$containerNameProperty.Value)
        $containerRootPrefix = $caseInventoryTestRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $containerFullPath.StartsWith($containerRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'container source file is outside the candidate tests tree.'
        }
        $containerRelativePath = [IO.Path]::GetRelativePath($caseInventoryTestRoot, $containerFullPath).Replace('\', '/')
        $containerKey = $containerRelativePath.ToUpperInvariant()
        if ($containerFileInventory.ContainsKey($containerKey)) {
            $caseInventoryErrors.Add("Pester returned a duplicate test container: $containerRelativePath")
        }
        else { $containerFileInventory.Add($containerKey, $containerRelativePath) }
    }
    catch {
        $caseInventoryErrors.Add("Pester container file identity is invalid: $($_.Exception.Message)")
    }
    $containerTotalProperty = $container.PSObject.Properties['TotalCount']
    if ($null -eq $containerTotalProperty) {
        $caseInventoryErrors.Add('A Pester container is missing its complete case count.')
        continue
    }
    $containerCaseTotal += [int]$containerTotalProperty.Value
}
foreach ($case in $discoveryCases) {
    if ([string]::IsNullOrEmpty($case.sourceFile)) { continue }
    $caseFileKey = $case.sourceFile.ToUpperInvariant()
    if (-not $expectedTestFileInventory.ContainsKey($caseFileKey)) {
        $caseInventoryErrors.Add("Pester discovered a case from an unexpected source file: $($case.sourceFile)")
    }
    elseif (-not $discoveredCaseFileInventory.ContainsKey($caseFileKey)) {
        $discoveredCaseFileInventory.Add($caseFileKey, $case.sourceFile)
    }
}
foreach ($fileKey in $expectedTestFileInventory.Keys) {
    if (-not $containerFileInventory.ContainsKey($fileKey)) {
        $caseInventoryErrors.Add("Pester omitted a candidate test-file container: $($expectedTestFileInventory[$fileKey])")
    }
}
foreach ($fileKey in $containerFileInventory.Keys) {
    if (-not $expectedTestFileInventory.ContainsKey($fileKey)) {
        $caseInventoryErrors.Add("Pester returned an unexpected test-file container: $($containerFileInventory[$fileKey])")
    }
}
$failedBlockItems = Get-CorePesterItems -Value $result.FailedBlocks -Context 'failed block inventory'
$failedContainerItems = Get-CorePesterItems -Value $result.FailedContainers -Context 'failed container inventory'
if ($discoveryCases.Count -ne $total) { $caseInventoryErrors.Add('Pester discovered case inventory count differs from TotalCount.') }
if ($executionCases.Count -ne $total) { $caseInventoryErrors.Add('Pester execution collection union differs from TotalCount.') }
if ($containerCaseTotal -ne $total) { $caseInventoryErrors.Add('Pester complete container case counts differ from TotalCount.') }
if ($failedBlockItems.Count -ne [int]$result.FailedBlocksCount) { $caseInventoryErrors.Add('Pester failed block count does not match its complete collection.') }
if ($failedContainerItems.Count -ne [int]$result.FailedContainersCount) { $caseInventoryErrors.Add('Pester failed container count does not match its complete collection.') }
if ($failedBlockItems.Count -gt 0) { $caseInventoryErrors.Add('Pester reported a failed block.') }
if ($failedContainerItems.Count -gt 0) { $caseInventoryErrors.Add('Pester reported a failed or undiscovered container.') }
if ([int]$result.FailedCount -gt 0) { $caseInventoryErrors.Add('Pester reported failed test cases.') }
if ([int]$result.InconclusiveCount -gt 0) { $caseInventoryErrors.Add('Pester reported inconclusive test cases.') }
if ([int]$result.NotRunCount -gt 0) { $caseInventoryErrors.Add('Pester reported discovered cases that did not run.') }
$fullShard = [pscustomobject]@{
    id = 'core-full'
    caseIdentities = @($executionCases | ForEach-Object { [string]$_.identity })
}
$shardUnionCheck = Test-CorePesterShardUnion -DiscoveredIdentities @($discoveryCases | ForEach-Object { [string]$_.identity }) -Shards @($fullShard)
if (-not $shardUnionCheck.IsValid) {
    foreach ($unionError in @($shardUnionCheck.Errors)) { $caseInventoryErrors.Add($unionError) }
}
$caseInventoryComplete = $caseInventoryErrors.Count -eq 0

$candidateSnapshotRoot = [IO.Path]::GetFullPath((Get-Location).Path)
$caseInventoryRunRoot = [IO.Path]::GetFullPath((Split-Path -Parent $candidateSnapshotRoot))
$caseInventoryCoreRunId = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_CORE_RUN_ID', 'Process')
if ([IO.Path]::GetFileName($caseInventoryRunRoot) -cne $caseInventoryCoreRunId -or
    [IO.Path]::GetFileName($candidateSnapshotRoot) -cne 'candidate') {
    $caseInventoryErrors.Add('Pester case inventory sidecar is not bound to the run-owned candidate parent.')
    $caseInventoryComplete = $false
}
else {
    $caseInventoryLedgerPath = Join-Path $caseInventoryRunRoot 'repository-pester-case-inventory-v1.json'
}
$caseInventoryComplete = $caseInventoryErrors.Count -eq 0

$caseInventoryLedger = [ordered]@{
    schemaVersion = 1
    report = 'standard-core-pester-case-inventory-v1'
    coreRunId = $caseInventoryCoreRunId
    candidateSnapshotIdentity = [ordered]@{ coreRunId = $caseInventoryCoreRunId; root = $candidateSnapshotRoot }
    candidateSnapshotSha256 = $candidateSnapshotBefore.Sha256
    pesterModule = [ordered]@{
        version = [string]$loadedPester[0].Version
        manifestPath = $verifiedPesterManifest
        moduleRoot = $verifiedPesterModuleRoot
        lockPath = $closureLockRecord.Path
        lockSha256 = $closureLockRecord.Sha256
        closureSha256Before = $preImportClosure.ClosureSha256
        closureSha256After = $postRunClosure.ClosureSha256
    }
    runPath = $caseInventoryRunPath
    runScope = 'complete-unfiltered-tests-tree'
    testFileInventory = @($expectedTestFileInventory.Values | Sort-Object)
    containerFileInventory = @($containerFileInventory.Values | Sort-Object)
    discoveredCaseFileInventory = @($discoveredCaseFileInventory.Values | Sort-Object)
    caseDiscoveryCount = $discoveryCases.Count
    caseExecutionCount = $executionCases.Count
    containerCount = $containerItems.Count
    failedBlockCount = $failedBlockItems.Count
    failedContainerCount = $failedContainerItems.Count
    terminalStatus = if ($caseInventoryComplete) { 'complete' } else { 'rejected' }
    reportedCounts = $reportedCaseCounts
    shardIdentity = 'core-full'
    shardCaseIdentities = @($fullShard.caseIdentities)
    shardUnion = [ordered]@{
        discoveryCount = $shardUnionCheck.DiscoveryCount
        executionUnionCount = $shardUnionCheck.UnionCount
        complete = $shardUnionCheck.IsValid
    }
    discoveryCases = @($discoveryCases.ToArray())
    executionCases = @($executionCases.ToArray())
    complete = $caseInventoryComplete
    errors = @($caseInventoryErrors.ToArray())
}

if (-not [string]::IsNullOrEmpty($caseInventoryLedgerPath)) {
    try {
        $ledgerJson = ConvertTo-Json -InputObject $caseInventoryLedger -Depth 8 -Compress -ErrorAction Stop
        $ledgerBytes = [Text.UTF8Encoding]::new($false).GetBytes($ledgerJson + "`n")
        $ledgerStream = [IO.FileStream]::new($caseInventoryLedgerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $ledgerStream.Write($ledgerBytes, 0, $ledgerBytes.Length)
            $ledgerStream.Flush($true)
        }
        finally { $ledgerStream.Dispose() }

        $ledgerItem = Get-Item -LiteralPath $caseInventoryLedgerPath -Force -ErrorAction Stop
        if ($ledgerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'the created case inventory sidecar is a reparse point.' }
        $readbackBytes = [IO.File]::ReadAllBytes($caseInventoryLedgerPath)
        if ($readbackBytes.Length -ne $ledgerBytes.Length) { throw 'case inventory sidecar readback is truncated.' }
        for ($index = 0; $index -lt $ledgerBytes.Length; $index++) {
            if ($readbackBytes[$index] -ne $ledgerBytes[$index]) { throw 'case inventory sidecar readback differs from the complete emitted ledger.' }
        }
        $readbackJson = [Text.UTF8Encoding]::new($false, $true).GetString($readbackBytes)
        $readbackLedger = ConvertFrom-Json -InputObject $readbackJson -ErrorAction Stop
        if ([string]$readbackLedger.report -cne 'standard-core-pester-case-inventory-v1' -or
            [string]$readbackLedger.coreRunId -cne $caseInventoryCoreRunId -or
            [int]$readbackLedger.caseDiscoveryCount -ne $discoveryCases.Count -or
            [int]$readbackLedger.caseExecutionCount -ne $executionCases.Count -or
            @($readbackLedger.discoveryCases).Count -ne $discoveryCases.Count -or
            @($readbackLedger.executionCases).Count -ne $executionCases.Count) {
            throw 'case inventory sidecar readback failed its complete count binding.'
        }
        $caseInventoryLedgerHash = (Get-FileHash -LiteralPath $caseInventoryLedgerPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($caseInventoryLedgerHash -notmatch '^[0-9a-f]{64}$') { throw 'case inventory sidecar SHA-256 is invalid.' }
        $caseInventoryLedgerWritten = $true
        [Console]::Error.WriteLine("Pester case inventory ledger: path=`"$caseInventoryLedgerPath`" sha256=$caseInventoryLedgerHash discovered=$($discoveryCases.Count) executed=$($executionCases.Count) complete=$caseInventoryComplete")
    }
    catch {
        $caseInventoryLedgerWritten = $false
        $caseInventoryComplete = $false
        [Console]::Error.WriteLine("Pester case inventory ledger incomplete: $($_.Exception.Message)")
    }
}
else {
    [Console]::Error.WriteLine('Pester case inventory ledger incomplete: no run-owned sidecar path could be established.')
}

foreach ($caseInventoryError in $caseInventoryErrors) {
    [Console]::Error.WriteLine("Pester case inventory error: $caseInventoryError")
}
# Pester's result objects retain actual start instants and durations even when
# the host buffers live InformationRecord lines. Emit a bounded timing ledger
# on stderr after completion; stdout remains the single machine JSON report.
$script:timingCharacters = 0
$script:timingLimit = 300000
$script:timingCapped = $false
function Write-PesterTiming {
    param([Parameter(Mandatory)] $Timing)
    $line = 'Pester timing ' + ($Timing | ConvertTo-Json -Compress -Depth 3)
    if ($script:timingCharacters + $line.Length -le $script:timingLimit) {
        [Console]::Error.WriteLine($line)
        $script:timingCharacters += $line.Length
    }
    elseif (-not $script:timingCapped) {
        [Console]::Error.WriteLine('Pester timing cap reached.')
        $script:timingCapped = $true
    }
}
foreach ($container in @($result.Containers)) {
    if ($null -eq $container -or $null -eq $container.ExecutedAt -or
        [DateTime]$container.ExecutedAt -eq [DateTime]::MinValue) { continue }
    $startUtc = ([DateTime]$container.ExecutedAt).ToUniversalTime()
    $duration = [TimeSpan]$container.Duration
    $timing = [ordered]@{
        kind = 'file'; name = ([string]$container.Name).Substring(0, [Math]::Min(200, ([string]$container.Name).Length))
        startedUtc = $startUtc.ToString('o'); endedUtc = $startUtc.Add($duration).ToString('o')
        elapsedMilliseconds = [Math]::Round($duration.TotalMilliseconds, 3)
        result = [string]$container.Result
    }
    Write-PesterTiming -Timing $timing
}
foreach ($failedContainer in @($result.FailedContainers)) {
    if ($null -eq $failedContainer -or
        ($null -ne $failedContainer.ExecutedAt -and [DateTime]$failedContainer.ExecutedAt -ne [DateTime]::MinValue)) { continue }
    $name = [string]$failedContainer.Name
    $timing = [ordered]@{
        kind = 'file-failure'; name = $name.Substring(0, [Math]::Min(200, $name.Length))
        observedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        startedUtc = $null; endedUtc = $null; elapsedMilliseconds = $null
        result = 'Failed'; timingAvailable = $false
    }
    Write-PesterTiming -Timing $timing
}
foreach ($test in @($result.Tests)) {
    if ($null -eq $test -or $null -eq $test.ExecutedAt -or
        [DateTime]$test.ExecutedAt -eq [DateTime]::MinValue) { continue }
    $startUtc = ([DateTime]$test.ExecutedAt).ToUniversalTime()
    $duration = [TimeSpan]$test.Duration
    $name = [string]$test.ExpandedPath
    $timing = [ordered]@{
        kind = 'case'; name = $name.Substring(0, [Math]::Min(200, $name.Length))
        startedUtc = $startUtc.ToString('o'); endedUtc = $startUtc.Add($duration).ToString('o')
        elapsedMilliseconds = [Math]::Round($duration.TotalMilliseconds, 3)
        result = [string]$test.Result
    }
    Write-PesterTiming -Timing $timing
}
$passed = [int]$result.PassedCount
$failed = [int]$result.FailedCount
$failedBlocks = [int]$result.FailedBlocksCount
$failedContainers = [int]$result.FailedContainersCount
$skipped = [int]$result.SkippedCount
foreach ($failedContainer in @($result.FailedContainers)) {
    [Console]::Error.WriteLine("Pester container failed: $($failedContainer.Name)")
    foreach ($failure in @($failedContainer.ErrorRecord)) {
        [Console]::Error.WriteLine("Pester container error: $($failure.Exception.Message)")
    }
}
foreach ($failedBlock in @($result.FailedBlocks)) {
    [Console]::Error.WriteLine("Pester block failed: $($failedBlock.Name)")
    foreach ($failure in @($failedBlock.ErrorRecord)) {
        [Console]::Error.WriteLine("Pester block error: $($failure.Exception.Message)")
    }
}
foreach ($failedTest in @($result.Failed)) {
    [Console]::Error.WriteLine("Pester test failed: $($failedTest.ExpandedPath)")
    foreach ($failure in @($failedTest.ErrorRecord)) {
        [Console]::Error.WriteLine("Pester test error: $($failure.Exception.Message)")
    }
}
$summary = [ordered]@{
    schemaVersion = 1
    report = 'standard-core-pester-result-v1'
    total = $total
    passed = $passed
    failed = $failed
    skipped = $skipped
}
if (-not $caseInventoryLedgerWritten -or -not $caseInventoryComplete -or
    $total -le 0 -or $passed -le 0 -or $failed -ne 0 -or $failedBlocks -ne 0 -or
    $failedContainers -ne 0 -or [int]$result.InconclusiveCount -ne 0 -or
    [int]$result.NotRunCount -ne 0 -or ($passed + $skipped) -ne $total) {
    [Console]::Error.WriteLine('Core Pester acceptance failed; no success report was emitted.')
    exit 1
}
[Console]::Out.WriteLine((ConvertTo-Json -InputObject $summary -Compress))
exit 0
