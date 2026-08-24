#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $StatePath,
    [switch] $ReviewCompletion,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This validator intentionally does not import the generator entrypoint. It
# independently reads committed Git objects, manifests,
# approvedSpans, and artifact sha256 values.

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-FileSha256 {
    param([string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Label)
    $rawRoot = [IO.Path]::GetFullPath($Root)
    $rootFull = if ($rawRoot -ceq [IO.Path]::GetPathRoot($rawRoot)) { $rawRoot } else { $rawRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootPrefix = if ($rootFull.EndsWith([IO.Path]::DirectorySeparatorChar) -or $rootFull.EndsWith([IO.Path]::AltDirectorySeparatorChar)) { $rootFull } else { $rootFull + [IO.Path]::DirectorySeparatorChar }
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its physical verification root."
    }
    $current = $pathFull
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (-not (Test-Path -LiteralPath $current)) { throw "$Label path component is missing." }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label path contains a symlink or reparse point."
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $pathFull }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "Unable to prove $Label physical containment." }
        $current = $parent
    }
    throw "Unable to prove $Label physical containment within 2048 path components."
}

function Assert-NoReparseTree {
    param([string] $Path, [string] $Root, [string] $Label)
    $treeFull = Assert-NoReparsePath -Path $Path -Root $Root -Label $Label
    if (-not (Test-Path -LiteralPath $treeFull -PathType Container)) { throw "$Label is not a directory." }
    foreach ($item in @(Get-ChildItem -LiteralPath $treeFull -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label contains a symlink or reparse point."
        }
    }
    $treeFull
}

function Assert-ClaimedArchiveIntegrity {
    param([Collections.IDictionary] $State)
    $Archive = $State.archive
    if (-not $Archive -or -not $Archive.Contains('path') -or -not $Archive.Contains('size') -or -not $Archive.Contains('sha256')) {
        throw 'claimed-archive evidence is incomplete.'
    }
    $archivePath = [string]$Archive.path
    $archivePath = Assert-NoReparsePath -Path $archivePath -Root ([string]$State.repositoryRoot) -Label 'Claimed source archive'
    if ([IO.Path]::GetFileName([string]$Archive.filename) -cne [string]$Archive.filename -or
        [string]$Archive.filename -match '^\s*$') {
        throw 'claimed-archive filename is not one safe file name.'
    }
    $expectedPath = [IO.Path]::GetFullPath((Join-Path (Join-Path ([string]$State.runRoot) 'source') ([string]$Archive.filename)))
    if ($archivePath -cne $expectedPath) {
        throw 'claimed-archive path differs from its fixed run-owned source path.'
    }
    $stream = [IO.File]::Open($archivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne [int64]$Archive.size) {
            throw 'claimed-archive size changed after claim.'
        }
        $actualSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        if ($actualSha256 -ne [string]$Archive.sha256) {
            throw 'claimed-archive SHA-256 changed after claim.'
        }
        $actualSha256
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-SourceReceiptIntegrity {
    param([Collections.IDictionary] $State)
    if ([int]$State.schemaVersion -lt 15) { return 'not-applicable: Schema 14 manual source' }
    if (-not $State.sourceReceipt -or -not $State.sourceAcquisition) { throw 'Schema 15 source receipt evidence is missing.' }
    foreach ($field in @('path', 'sha256', 'sourceRequestPath', 'sourceRequestSha256')) {
        if (-not $State.sourceReceipt.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$State.sourceReceipt[$field])) {
            throw "Schema 15 sourceReceipt.$field is missing."
        }
    }
    if (-not $State.sourceAcquisition.Contains('skillSourcePinPath') -or -not $State.sourceAcquisition.Contains('skillSourcePinSha256') -or
        [string]$State.sourceAcquisition.skillSourcePinPath -cne [string]$State.workflowSourcePinPath -or
        [string]$State.sourceAcquisition.skillSourcePinSha256 -cne [string]$State.workflowSourcePinSha256) {
        throw 'Schema 15 source acquisition Skill source pin differs from the verified workflow source pin.'
    }
    $sourceRunRoot = [IO.Path]::GetFullPath([string]$State.runRoot)
    $receiptFull = Assert-NoReparsePath -Path ([string]$State.sourceReceipt.path) -Root ([string]$State.repositoryRoot) -Label 'Schema 15 source receipt'
    $requestFull = Assert-NoReparsePath -Path ([string]$State.sourceReceipt.sourceRequestPath) -Root ([string]$State.repositoryRoot) -Label 'Schema 15 source request'
    $recordFull = Assert-NoReparsePath -Path ([string]$State.sourceAcquisition.recordPath) -Root ([string]$State.repositoryRoot) -Label 'Schema 15 source acquisition record'
    if ($receiptFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-receipt.json')) -or
        $requestFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-request.json')) -or
        $recordFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-acquisition.json'))) {
        throw 'Schema 15 source evidence is outside its fixed run-local paths.'
    }
    $verifier = Join-Path $PSScriptRoot 'Test-SourceReceipt.ps1'
    $verification = & $verifier -ReceiptPath $receiptFull -SourceRequestPath $requestFull -RunRoot $sourceRunRoot -PassThru
    if ($verification.result -cne 'passed') { throw 'Independent source receipt verifier rejected Schema 15 evidence.' }
    if ((Get-FileSha256 -Path ([string]$State.sourceReceipt.path)) -cne [string]$State.sourceReceipt.sha256) { throw 'Schema 15 source receipt SHA-256 changed.' }
    if ((Get-FileSha256 -Path ([string]$State.sourceReceipt.sourceRequestPath)) -cne [string]$State.sourceReceipt.sourceRequestSha256) { throw 'Schema 15 source request SHA-256 changed.' }
    if ([string]::IsNullOrWhiteSpace([string]$State.sourceAcquisition.recordPath) -or
        [string]::IsNullOrWhiteSpace([string]$State.sourceAcquisition.recordSha256) -or
        (Get-FileSha256 -Path ([string]$State.sourceAcquisition.recordPath)) -cne [string]$State.sourceAcquisition.recordSha256) {
        throw 'Schema 15 source acquisition record is missing or changed.'
    }
    $acquisition = Get-Content -LiteralPath $State.sourceAcquisition.recordPath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$acquisition.runId -cne [string]$State.runId -or [string]$acquisition.mod -cne [string]$State.repoModDirectory -or
        [string]$acquisition.sourceRequestPath -cne [string]$State.sourceReceipt.sourceRequestPath -or
        [string]$acquisition.sourceRequestSha256 -cne [string]$State.sourceReceipt.sourceRequestSha256 -or
        [string]$acquisition.receiptPath -cne [string]$State.sourceReceipt.path -or
        [string]$acquisition.receiptSha256 -cne [string]$State.sourceReceipt.sha256 -or
        [string]$acquisition.skillSourcePinPath -cne [string]$State.sourceAcquisition.skillSourcePinPath -or
        [string]$acquisition.skillSourcePinSha256 -cne [string]$State.sourceAcquisition.skillSourcePinSha256 -or
        [string]$acquisition.skillSourceCommit -cne [string]$State.workflowCommitOid -or
        [string]$acquisition.skillSourceContentSha256 -cne [string]$State.workflowSourceContentSha256 -or
        [string]$acquisition.result.status -cne 'delivered') {
        throw 'Schema 15 source acquisition record tuple changed.'
    }
    $receipt = Get-Content -LiteralPath $State.sourceReceipt.path -Raw | ConvertFrom-Json -AsHashtable
    $expectedAcquisitionResult = [ordered]@{
        result = 'passed'; status = 'delivered'; deliveredPath = [IO.Path]::GetFullPath([string]$receipt.deliveredPath)
        receiptPath = $receiptFull; receiptSha256 = [string]$State.sourceReceipt.sha256; timings = $receipt.timings
    }
    if (($acquisition.result | ConvertTo-Json -Depth 20 -Compress) -cne
        ($expectedAcquisitionResult | ConvertTo-Json -Depth 20 -Compress)) {
        throw 'Schema 15 source acquisition result changed.'
    }
    if ([string]$receipt.sha256 -cne [string]$State.archive.sha256) { throw 'Preserved delivered source and claimed archive SHA-256 differ.' }
    if ([string]$State.sourceAcquisition.receiptSha256 -cne [string]$State.sourceReceipt.sha256) { throw 'sourceAcquisition receipt binding changed.' }
    if (-not $State.stageTimings.Contains('acquire-source') -or [string]$State.stageTimings['acquire-source'].artifactSha256 -cne [string]$State.sourceReceipt.sha256) {
        throw 'acquire-source stage timing is not bound to the source receipt.'
    }
    [string]$State.sourceReceipt.sha256
}

function Assert-ReferenceIntegrity {
    param([Collections.IDictionary] $State)
    if (-not $State.Contains('workflowSourcePinPath') -or [string]::IsNullOrWhiteSpace([string]$State.workflowSourcePinPath)) {
        if ([int]$State.schemaVersion -ne 14) { throw 'Schema 15 state is missing its immutable Skill source pin.' }
        $legacyIntegrity = & (Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1') -PassThru
        if ($legacyIntegrity.result -cne 'passed' -or [string]$legacyIntegrity.authoringSourceCommit -cne [string]$State.workflowCommitOid -or
            [string]$State.workflowPath -cne [string]$legacyIntegrity.workflow.originalPath -or
            [string]$State.workflowBlobOid -cne [string]$legacyIntegrity.workflow.gitBlobOid -or
            [string]$State.workflowSha256 -cne [string]$legacyIntegrity.workflow.sha256 -or
            [string]$State.reviewBaselinePath -cne [string]$legacyIntegrity.reviewBaseline.originalPath -or
            [string]$State.reviewBaselineBlobOid -cne [string]$legacyIntegrity.reviewBaseline.gitBlobOid -or
            [string]$State.reviewBaselineSha256 -cne [string]$legacyIntegrity.reviewBaseline.sha256) {
            throw 'Legacy Schema 14 authoring reference tuple changed.'
        }
        return [string]$State.workflowSha256
    }
    foreach ($field in @('workflowSourcePinPath', 'workflowSourcePinSha256', 'workflowSourceRepository', 'workflowSourceContentSha256')) {
        if (-not $State.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$State[$field])) { throw "Recorded Skill source pin field is missing: $field" }
    }
    if ((Get-FileSha256 -Path ([string]$State.workflowSourcePinPath)) -cne [string]$State.workflowSourcePinSha256) {
        throw 'Recorded Skill source pin bytes changed.'
    }
    $integrity = & (Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1') -SkillSourcePinPath ([string]$State.workflowSourcePinPath) -PassThru
    if ($integrity.result -cne 'passed' -or -not $integrity.skillSourcePin -or
        [string]$integrity.skillSourcePin.pinSha256 -cne [string]$State.workflowSourcePinSha256 -or
        [string]$integrity.skillSourcePin.repository -cne [string]$State.workflowSourceRepository -or
        [string]$integrity.skillSourcePin.requestedRef -cne [string]$State.workflowRef -or
        [string]$integrity.skillSourcePin.resolvedCommit -cne [string]$State.workflowCommitOid -or
        [string]$integrity.skillSourcePin.contentSha256 -cne [string]$State.workflowSourceContentSha256) {
        throw 'Recorded immutable Skill source tuple no longer matches the verified package.'
    }
    foreach ($binding in @(
        [ordered]@{ name = 'Workflow'; expectedPath = $State.workflowPath; expectedBlob = $State.workflowBlobOid; expectedSha = $State.workflowSha256; expectedPackageSha = $State.workflowPackageSha256; actual = $integrity.workflow },
        [ordered]@{ name = 'Review Baseline'; expectedPath = $State.reviewBaselinePath; expectedBlob = $State.reviewBaselineBlobOid; expectedSha = $State.reviewBaselineSha256; expectedPackageSha = $State.reviewBaselinePackageSha256; actual = $integrity.reviewBaseline }
    )) {
        if ([string]$binding.expectedPath -cne [string]$binding.actual.path -or
            [string]$binding.expectedBlob -cne [string]$binding.actual.gitBlobOid -or
            [string]$binding.expectedPackageSha -cne [string]$binding.actual.packageSha256 -or
            [string]$binding.expectedSha -cne [string]$binding.actual.sha256) {
            throw "$($binding.name) reference binding changed."
        }
    }
    $references = @($State.referenceSources)
    $expectedRoles = if ([int]$State.schemaVersion -ge 15) { @('workflow', 'review-baseline', 'package-binding', 'skill', 'schema-15-extension') }
        else { @('workflow', 'review-baseline', 'package-binding', 'skill') }
    if ($references.Count -ne $expectedRoles.Count) { throw 'Recorded reference_sources count changed.' }
    foreach ($role in $expectedRoles) {
        $roleReferences = @($references | Where-Object { [string]$_.role -ceq $role })
        if ($roleReferences.Count -ne 1 -or [string]$roleReferences[0].sourceCommit -cne [string]$State.workflowCommitOid) {
            throw "Recorded reference_sources role is missing, duplicated, or pinned to another commit: $role"
        }
        $pinEntries = @($integrity.skillSourcePin.files | Where-Object { [string]$_.repositoryPath -ceq [string]$roleReferences[0].path })
        if ($pinEntries.Count -ne 1 -or [string]$roleReferences[0].blobOid -cne [string]$pinEntries[0].blobOid -or
            [int64]$roleReferences[0].size -ne [int64]$pinEntries[0].size -or [string]$roleReferences[0].sha256 -cne [string]$pinEntries[0].sha256) {
            throw "Recorded reference_sources evidence differs from the source pin: $role"
        }
    }
    if ([int]$State.schemaVersion -ge 15) {
        if ([string]$State.schema15Path -cne [string]$integrity.schema15.path -or
            [string]$State.schema15BlobOid -cne [string]$integrity.schema15.gitBlobOid -or
            [string]$State.schema15Sha256 -cne [string]$integrity.schema15.sha256) {
            throw 'Schema 15 extension reference binding changed.'
        }
        return [string]$State.schema15Sha256
    }
    [string]$State.workflowSha256
}

function Write-AtomicJson {
    param([string] $Path, $Value)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.validation-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Invoke-GitCheck {
    param([string] $WorkingDirectory, [string[]] $Arguments, [switch] $AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start Git validation.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $stdoutTask.Result.TrimEnd()
    $warning = $stderrTask.Result.TrimEnd()
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed: $warning $output"
    }
    [ordered]@{ exitCode = $exitCode; output = $output; warning = $warning }
}

function Invoke-GhCheck {
    param([string] $WorkingDirectory, [string[]] $Arguments, [switch] $AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start GitHub CLI validation.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [ordered]@{ exitCode = $process.ExitCode; output = $stdoutTask.Result.TrimEnd(); warning = $stderrTask.Result.TrimEnd() }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw "GitHub CLI validation failed: $($result.warning) $($result.output)" }
    $result
}

function Get-GitBlobBytes {
    param([string] $WorkingDirectory, [string] $Object)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start independent Git blob validation.' }
    $memory = [IO.MemoryStream]::new(); $process.StandardOutput.BaseStream.CopyTo($memory)
    $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Unable to read Git blob: $errorText" }
    $memory.ToArray()
}

function Test-CrlfNormalizationOnly {
    param([byte[]] $RawBytes, [byte[]] $IndexedBytes)
    $normalized = [IO.MemoryStream]::new()
    for ($index = 0; $index -lt $RawBytes.LongLength; $index++) {
        if ($RawBytes[$index] -eq 13 -and ($index + 1) -lt $RawBytes.LongLength -and $RawBytes[$index + 1] -eq 10) { continue }
        $normalized.WriteByte($RawBytes[$index])
    }
    $candidate = $normalized.ToArray()
    if ($candidate.LongLength -ne $IndexedBytes.LongLength) { return $false }
    for ($index = 0; $index -lt $candidate.LongLength; $index++) { if ($candidate[$index] -ne $IndexedBytes[$index]) { return $false } }
    $true
}

function Get-DiffCheckSignatures {
    param([string] $Output)
    @(
        $Output -split "`r?`n" |
            Where-Object { $_ -match '^.+:\d+: (?:trailing whitespace|new blank line at EOF)\.?$' } |
            ForEach-Object { $_.TrimEnd('.') } |
            Sort-Object -Unique
    )
}

function Get-ChangedPaths {
    param([string] $WorkingDirectory, [string] $BaseOid, [string] $HeadOid)
    @(
        (Invoke-GitCheck -WorkingDirectory $WorkingDirectory -Arguments @('-c', 'core.quotePath=false', 'diff', '--name-only', '--no-renames', "$BaseOid..$HeadOid")).output -split "`r?`n" |
            Where-Object { $_ }
    )
}

function Test-ApprovedSpanCandidate {
    param([byte[]] $Indexed, [byte[]] $Merged, [object[]] $ApprovedSpans)
    $ordered = @($ApprovedSpans | Sort-Object { [int64]$_.startByte })
    $indexedCursor = [int64]0
    $mergedCursor = [int64]0
    foreach ($span in $ordered) {
        $start = [int64]$span.startByte
        $length = [int64]$span.length
        if ($start -lt $indexedCursor -or $length -lt 0 -or ($start + $length) -gt $Indexed.LongLength) {
            throw 'approvedSpans overlap or escape indexed localization bytes.'
        }
        $unchangedLength = $start - $indexedCursor
        for ($offset = [int64]0; $offset -lt $unchangedLength; $offset++) {
            if ($Indexed[$indexedCursor + $offset] -ne $Merged[$mergedCursor + $offset]) {
                throw 'Merged candidate changed bytes outside approved localization spans.'
            }
        }
        $mergedCursor += $unchangedLength
        $oldBytes = [byte[]]::new($length)
        [Array]::Copy($Indexed, $start, $oldBytes, 0, $length)
        if ((Get-Sha256Bytes -Bytes $oldBytes) -ne [string]$span.oldSha256) {
            throw 'Approved localization oldSha256 does not match indexed bytes.'
        }
        $replacement = [Convert]::FromBase64String([string]$span.replacementBase64)
        if (($mergedCursor + $replacement.LongLength) -gt $Merged.LongLength) { throw 'Merged candidate truncates an approved replacement.' }
        for ($offset = [int64]0; $offset -lt $replacement.LongLength; $offset++) {
            if ($Merged[$mergedCursor + $offset] -ne $replacement[$offset]) { throw 'Merged candidate replacement bytes differ from the approval plan.' }
        }
        $indexedCursor = $start + $length
        $mergedCursor += $replacement.LongLength
    }
    $remaining = $Indexed.LongLength - $indexedCursor
    if (($mergedCursor + $remaining) -ne $Merged.LongLength) { throw 'Merged candidate length differs outside approved localization spans.' }
    for ($offset = [int64]0; $offset -lt $remaining; $offset++) {
        if ($Indexed[$indexedCursor + $offset] -ne $Merged[$mergedCursor + $offset]) {
            throw 'Merged candidate changed bytes outside approved localization spans.'
        }
    }
    $true
}

function Test-LocalizationWorksetCandidate {
    param([byte[]] $NewBytes, [byte[]] $MergedBytes, [object[]] $Edits)
    $spans = @($Edits | ForEach-Object {
        [ordered]@{
            startByte = [int64]$_.startByte
            length = [int64]$_.lengthByte
            oldSha256 = [string]$_.oldSha256
            replacementBase64 = [string]$_.replacementBase64
        }
    })
    try { $null = Test-ApprovedSpanCandidate -Indexed $NewBytes -Merged $MergedBytes -ApprovedSpans $spans }
    catch { throw "Candidate changed bytes outside approved localization workset edits. $($_.Exception.Message)" }
    $true
}

function Get-ImmutableWorksetContractSha256 {
    param($Workset)
    $unitContracts = @($Workset.units | ForEach-Object {
        [ordered]@{
            unitId = $_.unitId; sourceId = $_.sourceId; containerPath = $_.containerPath
            key = $_.key; occurrence = $_.occurrence; old = $_.old; new = $_.new
            changeType = $_.changeType; action = $_.action; blockedReason = $_.blockedReason
        }
    })
    $contract = [ordered]@{
        schemaVersion = $Workset.schemaVersion
        workflowSchemaVersion = $Workset.workflowSchemaVersion
        generatorVersion = $Workset.generatorVersion
        baseOid = $Workset.baseOid
        sourceId = $Workset.sourceId
        modRelativePath = $Workset.modRelativePath
        old = $Workset.old
        new = $Workset.new
        counts = $Workset.counts
        units = $unitContracts
    }
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress)))
}

$stateFull = [IO.Path]::GetFullPath($StatePath)
$stateRunRoot = Split-Path -Parent $stateFull
$null = Assert-NoReparsePath -Path $stateFull -Root ([IO.Path]::GetPathRoot($stateFull)) -Label 'Candidate state'
$state = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json -AsHashtable
if ([IO.Path]::GetFullPath([string]$state.runRoot) -cne $stateRunRoot -or [IO.Path]::GetFullPath([string]$state.statePath) -cne $stateFull) {
    throw 'Candidate state path differs from its fixed run root tuple.'
}
$null = Assert-NoReparsePath -Path $stateFull -Root ([string]$state.repositoryRoot) -Label 'Candidate state'

if ($ReviewCompletion) {
    $reviewChecks = [ordered]@{}
    $reviewErrors = [Collections.Generic.List[string]]::new()
    function Add-ReviewCheck {
        param([string] $Name, [scriptblock] $Action)
        try { $reviewChecks[$Name] = [ordered]@{ result = 'passed'; evidence = (& $Action) } }
        catch { $reviewChecks[$Name] = [ordered]@{ result = 'rejected'; evidence = $_.Exception.Message }; $reviewErrors.Add("${Name}: $($_.Exception.Message)") }
    }
    Add-ReviewCheck -Name 'claimed-archive' -Action {
        Assert-ClaimedArchiveIntegrity -State $state
    }
    Add-ReviewCheck -Name 'source-receipt' -Action {
        Assert-SourceReceiptIntegrity -State $state
    }
    Add-ReviewCheck -Name 'reference-integrity' -Action {
        Assert-ReferenceIntegrity -State $state
    }
    Add-ReviewCheck -Name 'candidate-gate' -Action {
        if ($state.candidateGate.status -ne 'passed') { throw 'Candidate Gate is not passed.' }
        if ((Get-FileSha256 -Path $state.candidateGate.validationReportPath) -ne $state.candidateGate.validationReportSha256) { throw 'Candidate Gate report SHA-256 changed.' }
        if (-not $state.diffReadability -or (Get-FileSha256 -Path $state.diffReadability.path) -ne $state.candidateGate.diffReadabilitySha256 -or $state.diffReadability.result -ne 'passed') { throw 'Diff readability evidence is missing, changed, or rejected.' }
        $state.candidateGate.validationReportSha256
    }
    Add-ReviewCheck -Name 'localization-workset-deletion' -Action {
        if ([int]$state.schemaVersion -lt 15) { return 'not-applicable: Schema 14 approved spans' }
        if (-not $state.localizationWorkset -or -not $state.localizationWorkset.Contains('deletedBeforePublish') -or -not [bool]$state.localizationWorkset.deletedBeforePublish) {
            throw 'Schema 15 localization workset deletion is not finalized.'
        }
        $worksetPath = [IO.Path]::GetFullPath([string]$state.localizationWorkset.path)
        if ($worksetPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.runRoot) 'review-artifacts/localization-workset.json'))) {
            throw 'Schema 15 localization workset deletion evidence has a non-canonical path.'
        }
        $null = Assert-NoReparsePath -Path (Split-Path -Parent $worksetPath) -Root ([string]$state.repositoryRoot) -Label 'Deleted localization workset parent'
        if (Test-Path -LiteralPath $worksetPath) { throw 'Schema 15 localization workset still exists after Candidate Gate.' }
        $receiptPath = Assert-NoReparsePath -Path ([string]$state.localizationWorkset.deletionReceiptPath) -Root ([string]$state.repositoryRoot) -Label 'Localization workset deletion receipt'
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Localization workset deletion receipt is missing.' }
        $receiptSha = Get-FileSha256 -Path $receiptPath
        if ($receiptSha -cne [string]$state.localizationWorkset.deletionReceiptSha256 -or
            $receiptSha -cne [string]$state.candidateGate.localizationWorksetDeletionReceiptSha256) {
            throw 'Localization workset deletion receipt is not bound to state and Candidate Gate.'
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$receipt.status -cne 'deleted' -or [string]$receipt.worksetSha256 -cne [string]$state.localizationWorkset.sha256) {
            throw 'Localization workset deletion receipt does not prove deletion of the reviewed workset.'
        }
        $reviewReportPath = Assert-NoReparsePath -Path ([string]$state.candidateGate.validationReportPath) -Root ([string]$state.repositoryRoot) -Label 'Candidate Gate report'
        $report = Get-Content -LiteralPath $reviewReportPath -Raw | ConvertFrom-Json -AsHashtable
        if (-not $report.Contains('worksetDeletion') -or [string]$report.worksetDeletion.status -cne 'deleted' -or
            [string]$report.worksetDeletion.receiptSha256 -cne $receiptSha -or
            [string]$report.worksetDeletion.worksetSha256 -cne [string]$state.localizationWorkset.sha256) {
            throw 'Candidate Gate report does not contain matching workset deletion evidence.'
        }
        $receiptSha
    }
    Add-ReviewCheck -Name 'local-review' -Action {
        if (-not $state.localReview -or -not (Test-Path -LiteralPath $state.localReview.path -PathType Leaf)) { throw 'Local review artifact is missing.' }
        if ((Get-FileSha256 -Path $state.localReview.path) -ne $state.localReview.sha256) { throw 'Local review artifact SHA-256 changed.' }
        $review = Get-Content -LiteralPath $state.localReview.path -Raw | ConvertFrom-Json -AsHashtable
        if ($review.result -ne 'passed' -or $review.headOid -ne $state.evidenceChain.fOid) { throw 'Local review is not passed for F.' }
        if (@($review.securityBlocking).Count -ne 0) { throw 'Local review contains a security-blocking finding.' }
        $unresolved = @($review.findings | Where-Object { $_.disposition -notin @('keep', 'resolved', 'out-of-scope') })
        if ($unresolved.Count -ne 0) { throw 'Local review contains findings without a completed disposition.' }
        $state.localReview.sha256
    }
    Add-ReviewCheck -Name 'local-remote-pr-head' -Action {
        $local = (Invoke-GitCheck -WorkingDirectory $state.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $remote = (Invoke-GitCheck -WorkingDirectory $state.worktreePath -Arguments @('ls-remote', '--heads', $state.remote, "refs/heads/$($state.branch)")).output.Split("`t")[0]
        $pr = (Invoke-GhCheck -WorkingDirectory $state.worktreePath -Arguments @('pr', 'view', [string]$state.prNumber, '--json', 'number,url,state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
        if ($local -ne $state.evidenceChain.fOid -or $remote -ne $local -or $pr.headRefOid -ne $local) { throw 'local, remote, PR head, and F are not identical.' }
        if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $state.pullRequestBase -or $pr.headRefName -ne $state.branch) { throw 'PR state, draft flag, base, or head is invalid.' }
        $local
    }
    Add-ReviewCheck -Name 'reviewed-oid' -Action {
        if ($state.reviewedOid -ne $state.evidenceChain.fOid) { throw 'reviewedOid does not equal F.' }
        if ($state.externalReview.status -notin @('completed', 'requested-pending', 'not-applicable', 'unavailable')) { throw 'External Review has no allowed zero-wait observation.' }
        if (-not $state.externalReview.Contains('pollingWaitSeconds') -or [int64]$state.externalReview.pollingWaitSeconds -ne 0) { throw 'External Review polling wait is missing or not zero.' }
        $state.reviewedOid
    }
    $reviewResultName = if ($reviewErrors.Count -eq 0) { 'passed' } else { 'rejected' }
    $reviewValidationPath = Join-Path $state.artifactsRoot 'review-completion-validation.json'
    $reviewReport = [ordered]@{ schemaVersion = 1; result = $reviewResultName; runId = $state.runId; headOid = $state.evidenceChain.fOid; checks = $reviewChecks; errors = @($reviewErrors); validatedAt = Get-UtcTimestamp }
    Write-AtomicJson -Path $reviewValidationPath -Value $reviewReport
    $reviewOutput = [ordered]@{ result = $reviewResultName; path = $reviewValidationPath; sha256 = Get-FileSha256 -Path $reviewValidationPath; errors = @($reviewErrors) }
    if ($PassThru) { $reviewOutput; if ($reviewResultName -ne 'passed') { throw "Review completion validation rejected the run: $($reviewErrors -join '; ')" } }
    else { $reviewOutput | ConvertTo-Json -Depth 20 -Compress; if ($reviewResultName -ne 'passed') { exit 1 } }
    return
}

$checks = [ordered]@{}
$errors = [Collections.Generic.List[string]]::new()

function Add-ValidationCheck {
    param([string] $Name, [scriptblock] $Action)
    try {
        $value = & $Action
        if ($value -eq $false) { throw "$Name returned false." }
        $checks[$Name] = [ordered]@{ result = 'passed'; evidence = $value }
    }
    catch {
        $checks[$Name] = [ordered]@{ result = 'rejected'; evidence = $_.Exception.Message }
        $errors.Add("${Name}: $($_.Exception.Message)")
    }
}

$chain = $state.evidenceChain
$worktree = [string]$state.worktreePath

Add-ValidationCheck -Name 'claimed-archive' -Action {
    Assert-ClaimedArchiveIntegrity -State $state
}

Add-ValidationCheck -Name 'physical-install-tree' -Action {
    $verifiedWorktree = Assert-NoReparsePath -Path $worktree -Root ([IO.Path]::GetPathRoot($worktree)) -Label 'Candidate worktree'
    $expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $verifiedWorktree ([string]$state.modRelativePath)))
    if ([IO.Path]::GetFullPath([string]$state.installRoot) -cne $expectedInstallRoot) {
        throw 'Candidate installRoot differs from the fixed MOD path in its worktree.'
    }
    $null = Assert-NoReparseTree -Path ([string]$state.installRoot) -Root $verifiedWorktree -Label 'Candidate installed MOD tree'
    $expectedInstallRoot
}

Add-ValidationCheck -Name 'source-receipt' -Action {
    Assert-SourceReceiptIntegrity -State $state
}

Add-ValidationCheck -Name 'reference-integrity' -Action {
    Assert-ReferenceIntegrity -State $state
}

Add-ValidationCheck -Name 'candidate-head' -Action {
    foreach ($field in @('c0Oid', 'c1Oid', 'fOid')) {
        if ([string]::IsNullOrWhiteSpace([string]$chain[$field])) { throw "Missing $field." }
    }
    $head = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    if ($head -ne $chain.fOid) { throw 'HEAD does not equal fOid.' }
    $ancestor = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('merge-base', '--is-ancestor', $chain.c0Oid, $chain.fOid) -AllowFailure
    if ($ancestor.exitCode -ne 0) { throw 'c0Oid is not an ancestor of fOid.' }
    $head
}

Add-ValidationCheck -Name 'parent-tree-invariants' -Action {
    $c1Parent = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c1Oid)^1")).output.Trim()
    $c1ParentTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c1Oid)^1^{tree}")).output.Trim()
    if ($c1Parent -ne $chain.c1ParentOid -or $c1ParentTree -ne $chain.c1ParentTreeOid -or $c1ParentTree -ne $chain.c0TreeOid) { throw 'C1 parent identity/tree does not equal the recorded C0 invariant.' }
    if ($state.localizationMode -eq 'zh-tw') {
        foreach ($field in @('c2Oid', 'c2TreeOid', 'c3Oid', 'c3TreeOid')) {
            if ([string]::IsNullOrWhiteSpace([string]$chain[$field])) { throw "Missing $field for active localization." }
        }
        $c2ParentTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c2Oid)^1^{tree}")).output.Trim()
        $c3ParentTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c3Oid)^1^{tree}")).output.Trim()
        if ($c2ParentTree -ne $chain.c2ParentTreeOid -or $c2ParentTree -ne $chain.c1TreeOid) { throw 'C2 parent tree does not equal C1 tree.' }
        if ($c3ParentTree -ne $chain.c3ParentTreeOid -or $c3ParentTree -ne $chain.c2TreeOid) { throw 'C3 parent tree does not equal C2 tree.' }
    }
    'parent tree invariants passed'
}

Add-ValidationCheck -Name 'commit-trees' -Action {
    foreach ($prefix in @('c0', 'c1', 'f')) {
        $actualTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain["${prefix}Oid"])^{tree}")).output.Trim()
        if ($actualTree -ne $chain["${prefix}TreeOid"]) { throw "$prefix tree OID mismatch." }
    }
    if ($state.localizationMode -eq 'zh-tw') {
        foreach ($prefix in @('c2', 'c3')) {
            $actualTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain["${prefix}Oid"])^{tree}")).output.Trim()
            if ($actualTree -ne $chain["${prefix}TreeOid"]) { throw "$prefix tree OID mismatch." }
        }
    }
    'C0/C1/C2/C3/F trees verified'
}

Add-ValidationCheck -Name 'layered-path-allowlists' -Action {
    $targets = @($state.evidenceTargetPaths)
    $c1Paths = Get-ChangedPaths -WorkingDirectory $worktree -BaseOid $chain.c1ParentOid -HeadOid $chain.c1Oid
    foreach ($path in $c1Paths) {
        if (-not $path.StartsWith($state.modRelativePath + '/', [StringComparison]::Ordinal) -or $path -cin $targets) { throw "C1 contains a target or out-of-MOD path: $path" }
    }
    if ($state.localizationMode -eq 'zh-tw') {
        foreach ($range in @([ordered]@{ base = $chain.c2ParentOid; head = $chain.c2Oid; name = 'C2' }, [ordered]@{ base = $chain.c3ParentOid; head = $chain.c3Oid; name = 'C3' })) {
            foreach ($path in Get-ChangedPaths -WorkingDirectory $worktree -BaseOid $range.base -HeadOid $range.head) {
                if ($path -cnotin $targets) { throw "$($range.name) contains a non-target path: $path" }
            }
        }
    }
    $finalAllowlist = @($state.metadataPaths | ForEach-Object { $_.Replace('\', '/') })
    foreach ($path in Get-ChangedPaths -WorkingDirectory $worktree -BaseOid $chain.c0Oid -HeadOid $chain.fOid) {
        if (-not $path.StartsWith($state.modRelativePath + '/', [StringComparison]::Ordinal) -and $path -cnotin $finalAllowlist) { throw "F contains an out-of-scope path: $path" }
    }
    'C1/C2/C3/F changed paths stay within their deterministic allowlists'
}

Add-ValidationCheck -Name 'diff-check' -Action {
    $finalCheck = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--check', "$($chain.c0Oid)..$($chain.fOid)") -AllowFailure
    if ($finalCheck.exitCode -eq 0) { return 'standard diff --check passed' }
    if ($finalCheck.exitCode -ne 2) { throw "Standard Git diff --check failed unexpectedly: $($finalCheck.output)" }

    $upstreamRanges = @([ordered]@{ base = $chain.c0Oid; head = $chain.c1Oid })
    if ($state.localizationMode -eq 'zh-tw') { $upstreamRanges += [ordered]@{ base = $chain.c1Oid; head = $chain.c2Oid } }
    $upstreamSignatures = @(
        foreach ($range in $upstreamRanges) {
            $check = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--check', "$($range.base)..$($range.head)") -AllowFailure
            if ($check.exitCode -notin @(0, 2)) { throw "Unable to verify upstream whitespace exceptions: $($check.output)" }
            Get-DiffCheckSignatures -Output $check.output
        }
    ) | Sort-Object -Unique
    if ($state.localizationMode -eq 'zh-tw') {
        $localizationCheck = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--check', "$($chain.c2Oid)..$($chain.c3Oid)") -AllowFailure
        if ($localizationCheck.exitCode -ne 0) { throw "Localization introduced whitespace errors: $($localizationCheck.output)" }
    }
    $finalSignatures = Get-DiffCheckSignatures -Output $finalCheck.output
    if ($finalSignatures.Count -eq 0) { throw "Standard Git diff --check produced an unrecognized rejection: $($finalCheck.output)" }
    foreach ($signature in $finalSignatures) {
        if ($signature -cnotin $upstreamSignatures) { throw "Final diff contains a non-upstream whitespace error: $signature" }
    }
    "standard diff --check accepted $($finalSignatures.Count) exact upstream whitespace exceptions"
}

Add-ValidationCheck -Name 'diff-readability' -Action {
    $ranges = @(
        [ordered]@{ name = 'c0-c1'; base = $chain.c0Oid; head = $chain.c1Oid },
        [ordered]@{ name = 'c0-f'; base = $chain.c0Oid; head = $chain.fOid }
    )
    if ($state.localizationMode -eq 'zh-tw') {
        $ranges += [ordered]@{ name = 'c1-c2'; base = $chain.c1Oid; head = $chain.c2Oid }
        $ranges += [ordered]@{ name = 'c2-c3'; base = $chain.c2Oid; head = $chain.c3Oid }
        if ($chain.fOid -ne $chain.c3Oid) { $ranges += [ordered]@{ name = 'c3-f'; base = $chain.c3Oid; head = $chain.fOid } }
    }
    $records = @()
    $noiseRanges = @()
    foreach ($range in $ranges) {
        $regular = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--numstat', '--no-renames', "$($range.base)..$($range.head)")).output
        $diagnostic = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--ignore-space-at-eol', '--numstat', '--no-renames', "$($range.base)..$($range.head)")).output
        $regularTotal = 0; foreach ($line in @($regular -split "`r?`n" | Where-Object { $_ -match '^(\d+)\s+(\d+)\s+' })) { $parts = $line -split '\s+', 3; $regularTotal += [int]$parts[0] + [int]$parts[1] }
        $diagnosticTotal = 0; foreach ($line in @($diagnostic -split "`r?`n" | Where-Object { $_ -match '^(\d+)\s+(\d+)\s+' })) { $parts = $line -split '\s+', 3; $diagnosticTotal += [int]$parts[0] + [int]$parts[1] }
        $lineEndingNoise = $regularTotal -gt 20 -and $regularTotal -gt ([Math]::Max(1, $diagnosticTotal) * 4)
        $records += [ordered]@{ name = $range.name; baseOid = $range.base; headOid = $range.head; standardNumstat = $regular; ignoreSpaceAtEolDiagnosticNumstat = $diagnostic; standardChangedLines = $regularTotal; diagnosticChangedLines = $diagnosticTotal; lineEndingNoise = $lineEndingNoise }
        if ($lineEndingNoise) { $noiseRanges += $range.name }
    }
    $readabilityPath = Join-Path $state.artifactsRoot 'diff-readability.json'
    $readabilityResult = if ($noiseRanges.Count -eq 0) { 'passed' } else { 'rejected' }
    Write-AtomicJson -Path $readabilityPath -Value ([ordered]@{ schemaVersion = 1; ranges = $records; result = $readabilityResult; generatedAt = Get-UtcTimestamp })
    $state.diffReadability = [ordered]@{ path = $readabilityPath; sha256 = Get-FileSha256 -Path $readabilityPath; result = $readabilityResult }
    if ($noiseRanges.Count -ne 0) { throw "Diff readability rejected line-ending noise in $($noiseRanges -join ', ')." }
    $state.diffReadability.sha256
}

Add-ValidationCheck -Name 'artifact-sha256' -Action {
    foreach ($artifact in @($state.extractionManifest, $state.rawInstallManifest, $state.installManifest, $state.gitIndexNormalization, $state.metadataPreview, $state.candidateTreeManifest, $state.evidenceReceipt)) {
        if (-not (Test-Path -LiteralPath $artifact.path -PathType Leaf)) { throw "Missing manifest or evidence artifact: $($artifact.path)" }
        if ((Get-FileSha256 -Path $artifact.path) -ne $artifact.sha256) { throw "Artifact sha256 mismatch: $($artifact.path)" }
    }
    foreach ($artifact in @($state.evidenceDiffs.Values)) {
        if ($artifact.Contains('status') -and $artifact.status -eq 'not-applicable') { continue }
        if (-not (Test-Path -LiteralPath $artifact.path -PathType Leaf) -or (Get-FileSha256 -Path $artifact.path) -ne $artifact.sha256) { throw "Git evidence artifact SHA-256 mismatch: $($artifact.path)" }
    }
    if ((Get-FileSha256 -Path $state.localizationManifestPath) -ne $state.stageTimings.localization.artifactSha256) { throw 'Localization manifest SHA-256 differs from its completed-stage receipt.' }
    'manifest and evidence sha256 values verified'
}

Add-ValidationCheck -Name 'raw-install-provenance' -Action {
    $extraction = Get-Content -LiteralPath $state.extractionManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $rawInstall = Get-Content -LiteralPath $state.rawInstallManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $prefix = ([string]$state.repoModDirectory).TrimEnd('/') + '/'
    $sourceFiles = @($extraction.files | ForEach-Object { [ordered]@{ path = if ($_.path.StartsWith($prefix, [StringComparison]::Ordinal)) { $_.path.Substring($prefix.Length) } else { throw "Extraction path is outside the one canonical MOD root: $($_.path)" }; size = $_.size; sha256 = $_.sha256 } } | Sort-Object { $_.path })
    $installedFiles = @($rawInstall.files | Sort-Object { $_.path })
    if ($sourceFiles.Count -ne $installedFiles.Count) { throw 'Raw install file count differs from extraction.' }
    for ($index = 0; $index -lt $sourceFiles.Count; $index++) {
        if ($sourceFiles[$index].path -cne $installedFiles[$index].path -or $sourceFiles[$index].size -ne $installedFiles[$index].size -or $sourceFiles[$index].sha256 -ne $installedFiles[$index].sha256) { throw 'Raw install differs from immutable extraction.' }
    }
    "$($sourceFiles.Count) raw archive files preserved"
}

Add-ValidationCheck -Name 'target-path-binding' -Action {
    $targetJson = ConvertTo-Json -InputObject @($state.evidenceTargetPaths) -Compress
    $actualSha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($targetJson))
    if ($actualSha -ne $state.evidenceTargetPathsSha256) { throw 'Evidence target path SHA-256 cannot be reconstructed.' }
    foreach ($record in @($state.localizationFiles)) {
        if ($record.relativePath -cnotin @($state.evidenceTargetPaths)) { throw 'Active localization path is outside evidenceTargetPaths.' }
    }
    $actualSha
}

Add-ValidationCheck -Name 'candidate-manifest' -Action {
    $manifest = Get-Content -LiteralPath $state.candidateTreeManifest.path -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.commitOid -ne $chain.fOid -or $manifest.treeOid -ne $chain.fTreeOid) { throw 'Candidate manifest is not bound to F and F tree.' }
    $listing = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('-c', 'core.quotePath=false', 'ls-tree', '-r', '-l', '--full-tree', $chain.fOid, '--', $state.modRelativePath)).output
    $actual = @()
    foreach ($line in @($listing -split "`r?`n" | Where-Object { $_ })) {
        if ($line -notmatch '^[0-7]{6} blob ([0-9a-f]{40})\s+(\d+)\t(.+)$') { throw "Unable to independently parse candidate Git tree entry: $line" }
        $repositoryPath = $Matches[3]
        $bytes = Get-GitBlobBytes -WorkingDirectory $worktree -Object $Matches[1]
        $actual += [ordered]@{ path = $repositoryPath.Substring(([string]$state.modRelativePath).Length).TrimStart('/'); blobOid = $Matches[1]; size = [int64]$Matches[2]; sha256 = Get-Sha256Bytes -Bytes $bytes }
    }
    $expected = @($manifest.files | Sort-Object { $_.path })
    $actual = @($actual | Sort-Object { $_.path })
    if ($actual.Count -ne $expected.Count) { throw 'Candidate Git tree path count differs from its manifest.' }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ($actual[$index].path -cne $expected[$index].path -or $actual[$index].blobOid -ne $expected[$index].blobOid -or $actual[$index].size -ne $expected[$index].size -or $actual[$index].sha256 -ne $expected[$index].sha256) { throw 'Candidate Git tree differs from its manifest.' }
    }
    "$($actual.Count) Git tree manifest files verified"
}

Add-ValidationCheck -Name 'install-normalization' -Action {
    $install = Get-Content -LiteralPath $state.installManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $candidate = Get-Content -LiteralPath $state.candidateTreeManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $normalization = Get-Content -LiteralPath $state.gitIndexNormalization.path -Raw | ConvertFrom-Json -AsHashtable
    $candidateByPath = @{}; foreach ($file in $candidate.files) { $candidateByPath[$file.path] = $file }
    $normalizationByPath = @{}; foreach ($file in $normalization.files) { $normalizationByPath[$file.path] = $file }
    foreach ($file in $install.files) {
        if (-not $candidateByPath.ContainsKey($file.path) -or -not $normalizationByPath.ContainsKey($file.path)) { throw "Install path is missing from Git candidate evidence: $($file.path). Candidate paths: $($candidateByPath.Keys -join ', '). Normalization paths: $($normalizationByPath.Keys -join ', ')." }
        $rawPath = Assert-NoReparsePath -Path (Join-Path $state.installRoot $file.path) -Root $worktree -Label 'Installed candidate file'
        $raw = [IO.File]::ReadAllBytes($rawPath)
        $candidateBytes = Get-GitBlobBytes -WorkingDirectory $worktree -Object ([string]$candidateByPath[$file.path].blobOid)
        $same = (Get-Sha256Bytes -Bytes $raw) -eq (Get-Sha256Bytes -Bytes $candidateBytes)
        if (-not $same -and -not (Test-CrlfNormalizationOnly -RawBytes $raw -IndexedBytes $candidateBytes)) { throw "Candidate changed bytes beyond CRLF-to-LF for $($file.path)" }
        if ((Get-Sha256Bytes -Bytes $candidateBytes) -ne $normalizationByPath[$file.path].indexedSha256 -and $file.path -notin @($state.localizationFiles.relativePath | ForEach-Object { $_.Substring(([string]$state.modRelativePath).Length).TrimStart('/') })) { throw "Candidate blob differs from normalization evidence for $($file.path)" }
    }
    'install, Git normalization, and candidate tree agree'
}

Add-ValidationCheck -Name 'localization-workset-boundary' -Action {
    if ([int]$state.schemaVersion -lt 15) { return 'not-applicable: Schema 14 approved spans' }
    if (-not $state.localizationWorkset -or [string]$state.localizationWorkset.status -cne 'applied') { throw 'Schema 15 applied localization workset evidence is missing.' }
    if ([string]$state.localizationMode -cne 'zh-tw' -or @($state.localizationFiles).Count -ne 1) {
        throw 'Schema 15 Candidate state must contain exactly one localization file.'
    }
    if ([string]$state.baseOid -cne [string]$chain.c0Oid) { throw 'Schema 15 state base OID differs from C0.' }
    $worksetPath = Assert-NoReparsePath -Path ([string]$state.localizationWorkset.path) -Root ([string]$state.repositoryRoot) -Label 'Localization workset'
    if ($worksetPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.runRoot) 'review-artifacts/localization-workset.json'))) {
        throw 'Localization workset is outside its fixed run-local path.'
    }
    if ((Get-FileSha256 -Path $worksetPath) -cne [string]$state.localizationWorkset.sha256) { throw 'Localization workset SHA-256 changed.' }
    $worksetFull = [IO.Path]::GetFullPath($worksetPath)
    $worktreeFull = [IO.Path]::GetFullPath([string]$state.worktreePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($worksetFull.StartsWith($worktreeFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Localization workset must never be inside the Git worktree.' }
    $workset = Get-Content -LiteralPath $worksetPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$workset.workflowSchemaVersion -ne 15 -or [string]$workset.status -cne 'applied') { throw 'Localization workset is not an applied Schema 15 artifact.' }
    if (-not $workset.Contains('apply') -or -not $workset.apply -or [string]$workset.apply.status -cne 'applied') {
        throw 'Localization workset apply receipt is not finalized.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$workset.immutableContractSha256) -or
        (Get-ImmutableWorksetContractSha256 -Workset $workset) -cne [string]$workset.immutableContractSha256) {
        throw 'Localization workset immutable contract changed.'
    }
    if ([string]$state.localizationWorkset.immutableContractSha256 -cne [string]$workset.immutableContractSha256) {
        throw 'Localization workset immutable contract differs from state evidence.'
    }
    $localizationManifestPath = Assert-NoReparsePath -Path ([string]$state.localizationManifestPath) -Root ([string]$state.repositoryRoot) -Label 'Localization manifest'
    if ($localizationManifestPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.artifactsRoot) 'localization-manifest.json'))) {
        throw 'Schema 15 localization manifest is outside its fixed artifact path.'
    }
    $localizationManifest = Get-Content -LiteralPath $localizationManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$localizationManifest.schemaVersion -ne 2 -or [int]$localizationManifest.workflowSchemaVersion -ne 15 -or
        [string]$localizationManifest.mode -cne 'zh-tw-workset' -or @($localizationManifest.files).Count -ne 1 -or
        @($localizationManifest.removedPaths).Count -ne 0 -or @($state.localizationRemovedPaths).Count -ne 0 -or
        [string]$localizationManifest.worksetPath -cne $worksetPath -or
        [string]$localizationManifest.worksetSha256 -cne [string]$state.localizationWorkset.sha256 -or
        [string]$localizationManifest.immutableContractSha256 -cne [string]$workset.immutableContractSha256) {
        throw 'Schema 15 localization manifest tuple differs from Candidate state or workset evidence.'
    }
    $classificationNames = @('unchanged', 'missing_zh_tw', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')
    if (@($localizationManifest.counts.Keys).Count -ne $classificationNames.Count -or @($state.localizationWorkset.counts.Keys).Count -ne $classificationNames.Count) {
        throw 'Schema 15 localization classification counts are malformed.'
    }
    foreach ($name in $classificationNames) {
        if (-not $localizationManifest.counts.Contains($name) -or -not $state.localizationWorkset.counts.Contains($name) -or
            [int]$localizationManifest.counts[$name] -ne [int]$workset.counts[$name] -or
            [int]$state.localizationWorkset.counts[$name] -ne [int]$workset.counts[$name]) {
            throw "Schema 15 localization classification count binding changed: $name"
        }
    }
    $stateRecord = $state.localizationFiles[0]
    $manifestRecord = $localizationManifest.files[0]
    $recordFields = @('relativePath', 'safeId', 'rawSha256', 'indexedSha256', 'mergedRawSha256', 'mergedSha256', 'artifactDirectory', 'decisionsSha256', 'worksetPath', 'worksetUnitCount', 'worksetEditCount')
    if (@($stateRecord.Keys).Count -ne $recordFields.Count -or @($manifestRecord.Keys).Count -ne $recordFields.Count) {
        throw 'Schema 15 localization file record fields are malformed.'
    }
    foreach ($field in $recordFields) {
        if (-not $stateRecord.Contains($field) -or -not $manifestRecord.Contains($field) -or
            [string]$stateRecord[$field] -cne [string]$manifestRecord[$field]) {
            throw "Schema 15 localization manifest file binding changed: $field"
        }
    }
    $expectedStagingRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path ([string]$state.runRoot) 'staging/localization-workset-input') ([string]$state.repoModDirectory)))
    $stagedLocalizationPath = [IO.Path]::GetFullPath([string]$workset.new.path)
    $relativeToMod = [IO.Path]::GetRelativePath($expectedStagingRoot, $stagedLocalizationPath).Replace('\', '/')
    if ($relativeToMod -eq '..' -or $relativeToMod.StartsWith('../', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeToMod)) {
        throw 'Schema 15 workset NEW localization path escapes fixed staging.'
    }
    $expectedRelativePath = ([string]$state.modRelativePath).TrimEnd('/') + '/' + $relativeToMod
    $expectedSafeId = (Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($expectedRelativePath))).Substring(0, 16)
    $expectedArtifactDirectory = [IO.Path]::GetFullPath((Join-Path (Join-Path ([string]$state.artifactsRoot) 'localization') $expectedSafeId))
    if ([string]$stateRecord.relativePath -cne $expectedRelativePath -or [string]$stateRecord.safeId -cne $expectedSafeId -or
        [IO.Path]::GetFullPath([string]$stateRecord.artifactDirectory) -cne $expectedArtifactDirectory -or
        [string]$stateRecord.worksetPath -cne $worksetPath -or
        [string]$stateRecord.decisionsSha256 -cne [string]$state.localizationWorkset.sha256 -or
        [int]$stateRecord.worksetUnitCount -ne @($workset.units).Count -or
        [int]$stateRecord.worksetEditCount -ne @($workset.apply.edits).Count) {
        throw 'Schema 15 localization file record differs from the unique workset output.'
    }
    if ([string]$workset.old.path -cnotin @($state.evidenceTargetPaths)) { throw 'Workset OLD localization path is outside evidenceTargetPaths.' }
    if (@($workset.units | Where-Object { $_.action -ceq 'BLOCKED' }).Count -ne 0) { throw 'Localization workset contains BLOCKED units.' }
    if (@($workset.units | Where-Object { $_.action -ceq 'AI_REQUIRED' -and $_.reviewStatus -cne 'approved' }).Count -ne 0) { throw 'Localization workset contains unapproved AI_REQUIRED units.' }
        if (@($workset.units | Where-Object { $_.action -cne 'AI_REQUIRED' -and ($_.reviewStatus -cne 'not-required' -or $null -ne $_.suggestedZhTwExpression) }).Count -ne 0) { throw 'Localization review fields were edited outside AI_REQUIRED units.' }
    foreach ($record in @($state.localizationFiles)) {
        if ([string]$record.relativePath -cnotin @($state.evidenceTargetPaths)) { throw 'Workset NEW localization path is outside evidenceTargetPaths.' }
        if ([string]$record.decisionsSha256 -cne [string]$state.localizationWorkset.sha256) { throw 'Localization file is not bound to the current workset SHA-256.' }
        $newPath = Join-Path ([string]$record.artifactDirectory) 'new.lua'
        $mergedPath = Join-Path ([string]$record.artifactDirectory) 'merged.lua'
        $mergedIndexedPath = Join-Path ([string]$record.artifactDirectory) 'merged-indexed.lua'
        $newPath = Assert-NoReparsePath -Path $newPath -Root ([string]$state.repositoryRoot) -Label 'Raw NEW localization evidence'
        $mergedPath = Assert-NoReparsePath -Path $mergedPath -Root ([string]$state.repositoryRoot) -Label 'Merged localization evidence'
        $mergedIndexedPath = Assert-NoReparsePath -Path $mergedIndexedPath -Root ([string]$state.repositoryRoot) -Label 'Merged indexed localization evidence'
        $newBytes = [IO.File]::ReadAllBytes($newPath)
        $mergedBytes = [IO.File]::ReadAllBytes($mergedPath)
        $mergedIndexedBytes = [IO.File]::ReadAllBytes($mergedIndexedPath)
        if ((Get-Sha256Bytes -Bytes $newBytes) -cne [string]$workset.apply.inputSha256 -or (Get-Sha256Bytes -Bytes $newBytes) -cne [string]$record.rawSha256) { throw 'Workset NEW bytes differ from raw localization evidence.' }
        if ((Get-Sha256Bytes -Bytes $mergedBytes) -cne [string]$workset.apply.outputSha256 -or (Get-Sha256Bytes -Bytes $mergedBytes) -cne [string]$record.mergedRawSha256) { throw 'Workset merged bytes differ from apply evidence.' }
        if ((Get-Sha256Bytes -Bytes $mergedIndexedBytes) -cne [string]$record.mergedSha256) { throw 'Workset merged indexed bytes changed.' }
        $receiptVerifier = Join-Path $PSScriptRoot 'Test-LocalizationWorksetReceipt.ps1'
        $receiptVerification = & $receiptVerifier -WorksetPath $worksetPath -NewPath $newPath -MergedPath $mergedPath `
            -RunRoot ([string]$state.runRoot) -RepositoryRoot ([string]$state.repositoryRoot) `
            -ExpectedBaseOid ([string]$chain.c0Oid) -ExpectedModRelativePath ([string]$state.modRelativePath) -PassThru
        if ($receiptVerification.result -cne 'passed') { throw 'Independent localization apply receipt verification failed.' }
        $null = Test-LocalizationWorksetCandidate -NewBytes $newBytes -MergedBytes $mergedBytes -Edits @($workset.apply.edits)
        $targetPath = Join-Path $worktree ([string]$record.relativePath)
        $targetPath = Assert-NoReparsePath -Path $targetPath -Root $worktree -Label 'Worktree localization target'
        if ((Get-FileSha256 -Path $targetPath) -cne [string]$record.mergedRawSha256) { throw 'Worktree localization target differs from workset merged raw bytes.' }
        $candidateBlob = Get-GitBlobBytes -WorkingDirectory $worktree -Object "$($chain.fOid):$([string]$record.relativePath)"
        if ((Get-Sha256Bytes -Bytes $candidateBlob) -cne [string]$record.mergedSha256) { throw 'F localization blob differs from workset merged indexed bytes.' }
    }
    "Workset units=$(@($workset.units).Count), edits=$(@($workset.apply.edits).Count), SHA-256=$($state.localizationWorkset.sha256)"
}

Add-ValidationCheck -Name 'localization-byte-boundary' -Action {
    if ([int]$state.schemaVersion -ge 15) { return 'not-applicable: Schema 15 localization workset' }
    if ($state.localizationMode -eq 'none') { return 'not-applicable: localization mode none' }
    $rawInstall = Get-Content -LiteralPath $state.rawInstallManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $normalization = Get-Content -LiteralPath $state.gitIndexNormalization.path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($record in @($state.localizationFiles)) {
        $newPath = Join-Path ([string]$record.artifactDirectory) 'new.lua'
        $indexedPath = Join-Path ([string]$record.artifactDirectory) 'indexed.lua'
        $mergedPath = Join-Path ([string]$record.artifactDirectory) 'merged.lua'
        $decisionsPath = Join-Path ([string]$record.artifactDirectory) 'decisions.json'
        if ((Get-FileSha256 -Path $decisionsPath) -ne $record.decisionsSha256) { throw 'Localization decisions artifact SHA-256 changed.' }
        $decision = Get-Content -LiteralPath $decisionsPath -Raw | ConvertFrom-Json -AsHashtable
        $raw = [IO.File]::ReadAllBytes($newPath)
        $indexed = [IO.File]::ReadAllBytes($indexedPath)
        $merged = [IO.File]::ReadAllBytes($mergedPath)
        if ((Get-Sha256Bytes -Bytes $raw) -ne $record.rawSha256) { throw 'Raw localization artifact sha256 mismatch.' }
        if ((Get-Sha256Bytes -Bytes $indexed) -ne $record.indexedSha256) { throw 'Indexed localization artifact sha256 mismatch.' }
        if ((Get-Sha256Bytes -Bytes $merged) -ne $record.mergedSha256) { throw 'Merged localization artifact sha256 mismatch.' }
        $relativeToMod = ([string]$record.relativePath).Substring(([string]$state.modRelativePath).Length).TrimStart('/')
        $rawEntry = @($rawInstall.files | Where-Object { $_.path -ceq $relativeToMod })
        $normalizationEntry = @($normalization.files | Where-Object { $_.path -ceq $relativeToMod })
        if ($rawEntry.Count -ne 1 -or $rawEntry[0].sha256 -ne $record.rawSha256 -or $rawEntry[0].size -ne $raw.LongLength) { throw 'Raw localization artifact differs from the raw-install manifest.' }
        if ($normalizationEntry.Count -ne 1 -or $normalizationEntry[0].rawSha256 -ne $record.rawSha256 -or $normalizationEntry[0].indexedSha256 -ne $record.indexedSha256) { throw 'Localization artifacts differ from Git-normalization evidence.' }
        $null = Test-ApprovedSpanCandidate -Indexed $indexed -Merged $merged -ApprovedSpans @($decision.approvedSpans)
        $targetPath = Join-Path $worktree ([string]$record.relativePath)
        if ((Get-FileSha256 -Path $targetPath) -ne $record.mergedSha256) { throw 'Worktree localization target differs from merged artifact.' }
        $candidateBlob = Get-GitBlobBytes -WorkingDirectory $worktree -Object "$($chain.fOid):$([string]$record.relativePath)"
        if ((Get-Sha256Bytes -Bytes $candidateBlob) -ne $record.mergedSha256) { throw 'F localization blob differs from the approved merged artifact.' }
    }
    foreach ($removedPath in @($state.localizationRemovedPaths)) {
        if ($removedPath -cnotin @($state.evidenceTargetPaths)) { throw 'Removed localization target is outside evidenceTargetPaths.' }
        if ((Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('cat-file', '-e', "$($chain.c0Oid):$removedPath") -AllowFailure).exitCode -ne 0) { throw 'Removed localization target did not exist at C0.' }
        if ((Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('cat-file', '-e', "$($chain.fOid):$removedPath") -AllowFailure).exitCode -eq 0) { throw 'Removed localization target still exists at F.' }
        $relativeToMod = $removedPath.Substring(([string]$state.modRelativePath).Length).TrimStart('/')
        if (@($rawInstall.files | Where-Object { $_.path -ceq $relativeToMod }).Count -ne 0) { throw 'Removed localization target still exists in the raw install.' }
    }
    'Only approved localization spans changed.'
}

$validationPath = Join-Path $state.artifactsRoot 'validation-report.json'
$resultName = if ($errors.Count -eq 0) { 'passed' } else { 'rejected' }
$sourceReceiptEvidence = if ($state.Contains('sourceReceipt')) { $state.sourceReceipt } else { $null }
$localizationWorksetEvidence = if ($state.Contains('localizationWorkset')) { $state.localizationWorkset } else { $null }
$report = [ordered]@{
    schemaVersion = 1
    result = $resultName
    runId = $state.runId
    candidateGate = $resultName
    evidenceChain = $chain
    workflow = [ordered]@{ commitOid = $state.workflowCommitOid; path = $state.workflowPath; blobOid = $state.workflowBlobOid; sha256 = $state.workflowSha256 }
    reviewBaseline = [ordered]@{ path = $state.reviewBaselinePath; blobOid = $state.reviewBaselineBlobOid; sha256 = $state.reviewBaselineSha256 }
    archive = $state.archive
    sourceReceipt = $sourceReceiptEvidence
    evidenceGeneration = $state.evidenceGeneration
    evidenceTargetPaths = $state.evidenceTargetPaths
    evidenceTargetPathsSha256 = $state.evidenceTargetPathsSha256
    evidenceDiffs = $state.evidenceDiffs
    diffReadability = $state.diffReadability
    localizationMode = $state.localizationMode
    localizationWorkset = $localizationWorksetEvidence
    manifests = [ordered]@{
        extraction = $state.extractionManifest
        rawInstall = $state.rawInstallManifest
        install = $state.installManifest
        candidate = $state.candidateTreeManifest
        gitIndexNormalization = $state.gitIndexNormalization
        metadataPreview = $state.metadataPreview
        evidenceReceipt = $state.evidenceReceipt
    }
    checks = $checks
    errors = @($errors)
    validatedAt = Get-UtcTimestamp
}
Write-AtomicJson -Path $validationPath -Value $report
$validationSha = Get-FileSha256 -Path $validationPath
$state.candidateGate = [ordered]@{
    status = $resultName
    c0Oid = $chain.c0Oid
    c1Oid = $chain.c1Oid
    c2Oid = $chain.c2Oid
    c3Oid = $chain.c3Oid
    fOid = $chain.fOid
    c0TreeOid = $chain.c0TreeOid
    c1TreeOid = $chain.c1TreeOid
    c2TreeOid = $chain.c2TreeOid
    c3TreeOid = $chain.c3TreeOid
    fTreeOid = $chain.fTreeOid
    c1ParentTreeOid = $chain.c1ParentTreeOid
    c2ParentTreeOid = $chain.c2ParentTreeOid
    c3ParentTreeOid = $chain.c3ParentTreeOid
    evidenceGeneration = $state.evidenceGeneration
    evidenceTargetPathsSha256 = $state.evidenceTargetPathsSha256
    extractionManifestSha256 = $state.extractionManifest.sha256
    rawInstallManifestSha256 = $state.rawInstallManifest.sha256
    installManifestSha256 = $state.installManifest.sha256
    candidateTreeManifestSha256 = $state.candidateTreeManifest.sha256
    gitIndexNormalizationSha256 = $state.gitIndexNormalization.sha256
    metadataPreviewSha256 = $state.metadataPreview.sha256
    evidenceGenerationReceiptSha256 = $state.evidenceReceipt.sha256
    diffReadabilitySha256 = $state.diffReadability.sha256
    localizationWorksetSha256 = if ([int]$state.schemaVersion -ge 15) { $state.localizationWorkset.sha256 } else { $null }
    sourceReceiptSha256 = if ([int]$state.schemaVersion -ge 15) { $state.sourceReceipt.sha256 } else { $null }
    validatorSha256 = Get-FileSha256 -Path $PSCommandPath
    validationReportPath = $validationPath
    validationReportSha256 = $validationSha
    validatedAt = Get-UtcTimestamp
}
$state.updatedAt = Get-UtcTimestamp
Write-AtomicJson -Path $StatePath -Value $state

$output = [ordered]@{
    result = $resultName
    runId = $state.runId
    candidateGate = $state.candidateGate
    validationReportPath = $validationPath
    validationReportSha256 = $validationSha
    errors = @($errors)
}

if ($PassThru) {
    $output
    if ($resultName -ne 'passed') { throw "Independent candidate validation rejected the run: $($errors -join '; ')" }
}
else {
    $output | ConvertTo-Json -Depth 20 -Compress
    if ($resultName -ne 'passed') { exit 1 }
}
