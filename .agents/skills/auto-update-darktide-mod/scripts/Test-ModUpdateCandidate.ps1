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
    param([string[]] $Arguments, [switch] $AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
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

$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable

if ($ReviewCompletion) {
    $reviewChecks = [ordered]@{}
    $reviewErrors = [Collections.Generic.List[string]]::new()
    function Add-ReviewCheck {
        param([string] $Name, [scriptblock] $Action)
        try { $reviewChecks[$Name] = [ordered]@{ result = 'passed'; evidence = (& $Action) } }
        catch { $reviewChecks[$Name] = [ordered]@{ result = 'rejected'; evidence = $_.Exception.Message }; $reviewErrors.Add("${Name}: $($_.Exception.Message)") }
    }
    Add-ReviewCheck -Name 'candidate-gate' -Action {
        if ($state.candidateGate.status -ne 'passed') { throw 'Candidate Gate is not passed.' }
        if ((Get-FileSha256 -Path $state.candidateGate.validationReportPath) -ne $state.candidateGate.validationReportSha256) { throw 'Candidate Gate report SHA-256 changed.' }
        if (-not $state.diffReadability -or (Get-FileSha256 -Path $state.diffReadability.path) -ne $state.candidateGate.diffReadabilitySha256 -or $state.diffReadability.result -ne 'passed') { throw 'Diff readability evidence is missing, changed, or rejected.' }
        $state.candidateGate.validationReportSha256
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
        $pr = (Invoke-GhCheck -Arguments @('pr', 'view', [string]$state.prNumber, '--json', 'number,url,state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
        if ($local -ne $state.evidenceChain.fOid -or $remote -ne $local -or $pr.headRefOid -ne $local) { throw 'local, remote, PR head, and F are not identical.' }
        if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $state.pullRequestBase -or $pr.headRefName -ne $state.branch) { throw 'PR state, draft flag, base, or head is invalid.' }
        $local
    }
    Add-ReviewCheck -Name 'reviewed-oid' -Action {
        if ($state.reviewedOid -ne $state.evidenceChain.fOid) { throw 'reviewedOid does not equal F.' }
        if ($state.externalReview.status -notin @('completed', 'requested-pending', 'not-applicable', 'unavailable')) { throw 'External Review has no allowed zero-wait observation.' }
        if ([int64]$state.externalReview.pollingWaitSeconds -ne 0) { throw 'External Review polling wait is not zero.' }
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
        $raw = [IO.File]::ReadAllBytes((Join-Path $state.installRoot $file.path))
        $candidateBytes = Get-GitBlobBytes -WorkingDirectory $worktree -Object ([string]$candidateByPath[$file.path].blobOid)
        $same = (Get-Sha256Bytes -Bytes $raw) -eq (Get-Sha256Bytes -Bytes $candidateBytes)
        if (-not $same -and -not (Test-CrlfNormalizationOnly -RawBytes $raw -IndexedBytes $candidateBytes)) { throw "Candidate changed bytes beyond CRLF-to-LF for $($file.path)" }
        if ((Get-Sha256Bytes -Bytes $candidateBytes) -ne $normalizationByPath[$file.path].indexedSha256 -and $file.path -notin @($state.localizationFiles.relativePath | ForEach-Object { $_.Substring(([string]$state.modRelativePath).Length).TrimStart('/') })) { throw "Candidate blob differs from normalization evidence for $($file.path)" }
    }
    'install, Git normalization, and candidate tree agree'
}

Add-ValidationCheck -Name 'localization-byte-boundary' -Action {
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
$report = [ordered]@{
    schemaVersion = 1
    result = $resultName
    runId = $state.runId
    candidateGate = $resultName
    evidenceChain = $chain
    workflow = [ordered]@{ commitOid = $state.workflowCommitOid; path = $state.workflowPath; blobOid = $state.workflowBlobOid; sha256 = $state.workflowSha256 }
    reviewBaseline = [ordered]@{ path = $state.reviewBaselinePath; blobOid = $state.reviewBaselineBlobOid; sha256 = $state.reviewBaselineSha256 }
    archive = $state.archive
    evidenceGeneration = $state.evidenceGeneration
    evidenceTargetPaths = $state.evidenceTargetPaths
    evidenceTargetPathsSha256 = $state.evidenceTargetPathsSha256
    evidenceDiffs = $state.evidenceDiffs
    diffReadability = $state.diffReadability
    localizationMode = $state.localizationMode
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
