# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Import-Module (Join-Path $PSScriptRoot 'PathSafety.psm1') -Force -ErrorAction Stop

function Get-MergeFinalizationDisposition {
    param(
        [Parameter(Mandatory)][string] $PullRequestState,
        [Parameter(Mandatory)][string] $ReviewedOid,
        [AllowEmptyString()][string] $ObservedHeadOid
    )
    switch ($PullRequestState.ToUpperInvariant()) {
        'OPEN' {
            if ($ObservedHeadOid -ceq $ReviewedOid) { 'awaiting-merge' }
            else { 'open-head-changed-after-review' }
        }
        'CLOSED' { 'closed-without-merge' }
        'MERGED' {
            if ($ObservedHeadOid -ceq $ReviewedOid) { 'finalize-reviewed-head' }
            else { 'reconcile-changed-head' }
        }
        default { throw "Unsupported pull request state: $PullRequestState" }
    }
}

function Set-MergeStateValue {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()] $Value
    )
    $State[$Name] = $Value
}

function Test-ModUpdateFinalizationStateStatus {
    param(
        [Parameter(Mandatory)][string] $Status,
        [AllowEmptyCollection()][string[]] $CompletedStages = @(),
        [AllowNull()][Collections.IDictionary] $WaitingReason
    )
    if ($Status -ceq 'awaiting-user-merge') { return $true }
    if ($Status -ceq 'merged' -and $CompletedStages -contains 'finalize-merge') { return $true }
    $Status -ceq 'waiting-user' -and $WaitingReason -and
        [string]$WaitingReason.code -in @(
            'pull_request_closed_without_merge',
            'merge_topology_requires_reconciliation',
            'open_head_changed_after_review'
        )
}

function Test-ModUpdateWorktreeRegistered {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Porcelain,
        [Parameter(Mandatory)][string] $ExpectedPath
    )
    $normalizePath = {
        param([string] $Value)
        $portable = $Value.Replace([char]92, [IO.Path]::DirectorySeparatorChar).Replace([char]47, [IO.Path]::DirectorySeparatorChar)
        [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($portable))
    }
    $expected = & $normalizePath $ExpectedPath
    foreach ($line in @($Porcelain -split '\r?\n')) {
        if (-not $line.StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
        try {
            $candidate = & $normalizePath $line.Substring('worktree '.Length)
        }
        catch { continue }
        if ($candidate.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

function Assert-ModUpdateGitIdentities {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $repository = [string]$State.repositoryRoot
    $remote = [string]$State.remote
    $remoteNames = @(
        (Invoke-Git -WorkingDirectory $repository -Arguments @('remote')).output -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($remoteNames -cnotcontains $remote) { throw 'Recorded Git remote does not exist in the target repository.' }

    foreach ($refName in @(
        "refs/heads/$($State.branch)",
        "refs/heads/$($State.pullRequestBase)",
        "refs/remotes/$remote/$($State.pullRequestBase)",
        "refs/darktide-finalization/$($State.runId)/pr-head"
    )) {
        $check = Invoke-Git -WorkingDirectory $repository -Arguments @('check-ref-format', $refName) -AllowFailure
        if ($check.exitCode -ne 0) { throw "Recorded Git ref is invalid: $refName" }
    }
}

function Get-ModUpdateArchiveLocations {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $filename = [string]$State.archive.filename
    if ([string]::IsNullOrWhiteSpace($filename) -or [IO.Path]::GetFileName($filename) -cne $filename -or
        $filename.TrimEnd([char[]]' .') -cne $filename -or $filename.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $filename -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
        throw 'Finalization archive filename is not one safe file name.'
    }
    $sourceRoot = Join-Path ([string]$State.runRoot) 'source'
    $sourcePath = Assert-ContainedPath -Candidate (Join-Path (Join-Path ([string]$State.runRoot) 'source') $filename) `
        -Root $sourceRoot -Label 'Run-owned archive'
    $sourcePath = Assert-NoReparsePath -Path $sourcePath -Root ([string]$State.runRoot) -Label 'Run-owned archive' -AllowMissing
    if (-not ([IO.Path]::GetFullPath([string]$State.archive.path)).Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Run-owned archive path differs from its canonical location.'
    }
    $finishedRoot = Join-Path ([string]$State.repositoryRoot) 'AI Auto Update/Finished'
    $finishedPath = Assert-ContainedPath -Candidate (Join-Path $finishedRoot $filename) -Root $finishedRoot -Label 'Finished archive'
    $finishedPath = Assert-NoReparsePath -Path $finishedPath -Root ([string]$State.repositoryRoot) -Label 'Finished archive' -AllowMissing
    [ordered]@{
        filename = $filename
        sourceRoot = $sourceRoot
        sourcePath = $sourcePath
        finishedRoot = $finishedRoot
        finishedPath = $finishedPath
    }
}

function Assert-MergeFileTuple {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][int64] $Size,
        [Parameter(Mandatory)][string] $Sha256
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (Test-PortableReparseItem -Path $Path -Item $item -Label 'Immutable merge file') -or
        $item.Length -ne $Size -or (Get-FileSha256 -Path $item.FullName) -cne $Sha256) {
        throw "Immutable file tuple mismatch: $Path"
    }
    $item.FullName
}

function Get-ModUpdateFingerprintPath {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $fingerprintCandidates = @($State.metadataPaths | Where-Object {
        ([string]$_).Replace('\', '/') -match '^\.hash/[^/]+\.hash$'
    })
    if ($fingerprintCandidates.Count -ne 1) { throw 'Run state must identify exactly one formal fingerprint path.' }
    $path = ([string]$fingerprintCandidates[0]).Replace('\', '/')
    if ([IO.Path]::IsPathRooted($path) -or $path.Split('/') -contains '..') {
        throw 'Formal fingerprint path is not a safe repository-relative path.'
    }
    $path
}

function Get-ModUpdateFingerprintRecord {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $CommitOid,
        [Parameter(Mandatory)][string] $OriginMainOid,
        [Parameter(Mandatory)][Collections.IDictionary] $PullRequest
    )
    $fingerprintPath = Get-ModUpdateFingerprintPath -State $State
    $objectName = "${CommitOid}:$fingerprintPath"
    $mainObjectName = "${OriginMainOid}:$fingerprintPath"
    $fingerprintBlobOid = (Invoke-Git -WorkingDirectory ([string]$State.repositoryRoot) -Arguments @('rev-parse', $objectName)).output.Trim()
    $mainBlobOid = (Invoke-Git -WorkingDirectory ([string]$State.repositoryRoot) -Arguments @('rev-parse', $mainObjectName)).output.Trim()
    if ($fingerprintBlobOid -cne $mainBlobOid) { throw 'Merged main fingerprint differs from the observed merged PR head.' }

    $bytes = Get-GitBlobBytes -WorkingDirectory ([string]$State.repositoryRoot) -Object $fingerprintBlobOid
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).Replace("`r`n", "`n")
    $expected = [ordered]@{
        filename = [string]$State.archive.filename
        size_bytes = [string][int64]$State.archive.size
        sha256 = [string]$State.archive.sha256
    }
    foreach ($name in $expected.Keys) {
        $line = "$name=$($expected[$name])"
        if (@($text -split "`n" | Where-Object { $_ -ceq $line }).Count -ne 1) {
            throw "Merged formal fingerprint does not contain the unique immutable $name value."
        }
    }

    [ordered]@{
        schemaVersion = 1
        runId = [string]$State.runId
        mod = [string]$State.mod
        repositoryPath = $fingerprintPath
        fingerprintCommitOid = $CommitOid
        fingerprintBlobOid = $fingerprintBlobOid
        fingerprintBlobSizeBytes = $bytes.LongLength
        fingerprintBlobSha256 = Get-Sha256Bytes -Bytes $bytes
        mergedHeadOid = [string]$PullRequest.headRefOid
        mergeCommitOid = [string]$PullRequest.mergeCommit.oid
        originMainOid = $OriginMainOid
        archive = [ordered]@{
            filename = [string]$State.archive.filename
            size = [int64]$State.archive.size
            sha256 = [string]$State.archive.sha256
        }
        result = 'verified-merged-fingerprint-matches-source'
        verifiedAt = Get-UtcTimestamp
    }
}

function Get-ModUpdateGitOutputBytes {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $memory = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw 'Unable to start Git evidence capture.' }
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
            Update-ActiveReservationHeartbeat
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $warning = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Git evidence capture failed: $warning" }
        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Copy-ModUpdateEvidenceTree {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    $sourceFull = Assert-NoReparseTree -Path $Source -Root ([string]$script:activeReservationState.repositoryRoot) -Label 'Finalization evidence source'
    $destinationFull = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $destinationFull -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
    }
    foreach ($file in Get-ChildItem -LiteralPath $sourceFull -File -Recurse -Force | Sort-Object FullName) {
        if (Test-PortableReparseItem -Path $file.FullName -Item $file -Label 'Finalization evidence') { throw 'Finalization evidence contains a reparse point.' }
        $relative = [IO.Path]::GetRelativePath($sourceFull, $file.FullName)
        $target = Assert-ContainedPath -Candidate (Join-Path $destinationFull $relative) -Root $destinationFull -Label 'Finalization evidence target'
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-FileWithHeartbeat -SourcePath $file.FullName -DestinationPath $target
        if ((Get-FileSha256 -Path $target) -cne (Get-FileSha256 -Path $file.FullName)) {
            throw "Finalization evidence copy changed bytes: $relative"
        }
    }
}

function Get-ModUpdateEvidenceManifest {
    param([Parameter(Mandatory)][string] $Root)
    $rootFull = [IO.Path]::GetFullPath($Root)
    @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($rootFull, $_.FullName).Replace('\', '/')
            size = $_.Length
            sha256 = Get-FileSha256 -Path $_.FullName
        }
    })
}

function Assert-ModUpdateFinalEvidence {
    param(
        [Parameter(Mandatory)][string] $EvidencePath,
        [Parameter(Mandatory)][string] $RunId
    )
    $evidenceFull = Assert-NoReparseTree -Path $EvidencePath -Root ([string]$script:activeReservationState.repositoryRoot) -Label 'Final merge evidence'
    $stateFinalPath = Join-Path $evidenceFull 'state-final.json'
    $manifestPath = Join-Path $evidenceFull 'archive-manifest.json'
    $stateFinal = Get-Content -LiteralPath $stateFinalPath -Raw | ConvertFrom-Json -AsHashtable
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$stateFinal.runId -cne $RunId -or [string]$stateFinal.disposition -cne 'merge-evidence-archived' -or
        [string]$manifest.runId -cne $RunId -or [int]$manifest.schemaVersion -ne 1) {
        throw 'Final merge evidence belongs to a different run or contract.'
    }
    foreach ($entry in @($manifest.files)) {
        $archivedPath = Assert-ContainedPath -Candidate (Join-Path $evidenceFull ([string]$entry.path)) -Root $evidenceFull -Label 'Archived finalization evidence'
        $null = Assert-MergeFileTuple -Path $archivedPath -Size ([int64]$entry.size) -Sha256 ([string]$entry.sha256)
    }
    [ordered]@{ stateFinal = $stateFinal; manifest = $manifest }
}

function Remove-ModUpdateOwnedTree {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Label
    )
    $fullPath = Assert-NoReparseTree -Path $Path -Root $Root -Label $Label
    $rootFull = [IO.Path]::GetFullPath($Root)
    if ($fullPath -ceq $rootFull) { throw "$Label cannot be the containment root." }
    Remove-DirectoryTreeWithHeartbeat -Path $fullPath
}

function Assert-ModUpdateMergeFinalizationState {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    foreach ($field in @('runId', 'repositoryRoot', 'statePath', 'runRoot', 'artifactsRoot', 'worktreePath', 'branch', 'remote', 'pullRequestBase', 'prNumber', 'prUrl', 'published', 'archive', 'metadataPaths', 'evidenceChain', 'candidateGate', 'localReview', 'reviewedOid', 'completedStages', 'claimPath', 'modLockPath', 'modLockKey')) {
        if (-not $State.Contains($field) -or $null -eq $State[$field] -or [string]::IsNullOrWhiteSpace([string]$State[$field])) {
            throw "Merge finalization state is missing $field."
        }
    }
    $reviewedOid = [string]$State.reviewedOid
    $isResumingFinalization = [string]$State.status -ceq 'merged' -and @($State.completedStages) -contains 'finalize-merge'
    if (-not (Test-ModUpdateFinalizationStateStatus -Status ([string]$State.status) `
            -CompletedStages @($State.completedStages) -WaitingReason $(if ($State.Contains('waitingReason')) { $State.waitingReason } else { $null })) -or
        -not [bool]$State.published -or
        $reviewedOid -notmatch '^[0-9a-f]{40}$' -or $reviewedOid -cne [string]$State.evidenceChain.fOid -or
        [string]$State.candidateGate.status -cne 'passed' -or [string]$State.candidateGate.fOid -cne $reviewedOid -or
        [string]$State.localReview.result -cne 'passed') {
        throw 'Run, Candidate Gate, and local Review are not the same finalizable F tuple.'
    }
    foreach ($stage in @('validate', 'publish', 'review-snapshot')) {
        if (@($State.completedStages) -notcontains $stage) { throw "Merge finalization requires completed stage $stage." }
    }
    foreach ($value in @([string]$State.remote, [string]$State.pullRequestBase, [string]$State.branch)) {
        if ($value.StartsWith('-', [StringComparison]::Ordinal) -or $value.Contains("`0")) {
            throw 'Merge finalization rejected an option-like Git identity.'
        }
    }
    Assert-ModUpdateGitIdentities -State $State
    Assert-LockOwner -State $State
    $archiveLocations = Get-ModUpdateArchiveLocations -State $State
    $sourceExists = Test-Path -LiteralPath ([string]$archiveLocations.sourcePath) -PathType Leaf
    $finishedArchive = [string]$archiveLocations.finishedPath
    if ($sourceExists) {
        $null = Assert-MergeFileTuple -Path ([string]$archiveLocations.sourcePath) -Size ([int64]$State.archive.size) -Sha256 ([string]$State.archive.sha256)
    }
    elseif ($isResumingFinalization -and (Test-Path -LiteralPath $finishedArchive -PathType Leaf)) {
        $null = Assert-MergeFileTuple -Path $finishedArchive -Size ([int64]$State.archive.size) -Sha256 ([string]$State.archive.sha256)
    }
    else { throw 'Finalization cannot find the immutable archive in its run or Finished location.' }
    $reviewedOid
}

function Write-ModUpdateMergeObservation {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $PullRequest,
        [Parameter(Mandatory)][string] $Disposition
    )
    $path = Join-Path ([string]$State.artifactsRoot) 'merge-finalization-observation.json'
    Write-AtomicJson -Path $path -Value ([ordered]@{
        schemaVersion = 1
        runId = [string]$State.runId
        disposition = $Disposition
        observedAt = Get-UtcTimestamp
        pullRequest = $PullRequest
    })
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path }
}

function Set-ModUpdateChangedHeadState {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $PullRequest,
        [Parameter(Mandatory)][string] $OriginMainOid,
        [Parameter(Mandatory)][string] $FingerprintSha256,
        [Parameter(Mandatory)][string] $ReconciliationPath,
        [Parameter(Mandatory)][string] $ReconciliationSha256
    )
    $mergedHeadOid = [string]$PullRequest.headRefOid
    Set-MergeStateValue -State $State -Name 'status' -Value 'waiting-user'
    Set-MergeStateValue -State $State -Name 'waitingReason' -Value ([ordered]@{
        code = 'merged_head_changed_after_review'
        message = 'The merged PR head differs from reviewed F. The actual fingerprint and exact diff are retained; choose an append-only recovery from the recorded merged content before final cleanup.'
        reconciliationPath = $ReconciliationPath
    })
    Set-MergeStateValue -State $State -Name 'headOid' -Value $mergedHeadOid
    Set-MergeStateValue -State $State -Name 'mergedHeadOid' -Value $mergedHeadOid
    Set-MergeStateValue -State $State -Name 'mergeCommitOid' -Value ([string]$PullRequest.mergeCommit.oid)
    Set-MergeStateValue -State $State -Name 'mergedAt' -Value ([string]$PullRequest.mergedAt)
    Set-MergeStateValue -State $State -Name 'originMainOid' -Value $OriginMainOid
    Set-MergeStateValue -State $State -Name 'mergeFingerprintSha256' -Value $FingerprintSha256
    Set-MergeStateValue -State $State -Name 'postMergeReconciliation' -Value ([ordered]@{ path = $ReconciliationPath; sha256 = $ReconciliationSha256 })
    Set-MergeStateValue -State $State -Name 'reviewedOid' -Value $null
    Set-MergeStateValue -State $State -Name 'localReview' -Value $null
    Set-MergeStateValue -State $State -Name 'reviewSnapshot' -Value $null
    Set-MergeStateValue -State $State -Name 'lastError' -Value $null
    $State.completedStages = @($State.completedStages | Where-Object { $_ -notin @('validate', 'publish', 'review-snapshot', 'finalize-merge') })
    $State.candidateGate = [ordered]@{ status = 'not-run' }
    $State
}

function Invoke-ModUpdateChangedHeadReconciliation {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $PullRequest,
        [Parameter(Mandatory)][Collections.IDictionary] $Fingerprint,
        [Parameter(Mandatory)][string] $OriginMainOid,
        [Parameter(Mandatory)][Collections.IDictionary] $Stage
    )
    $reviewedOid = [string]$State.reviewedOid
    $mergedHeadOid = [string]$PullRequest.headRefOid
    $rejectedRoot = Join-Path ([string]$State.artifactsRoot) "rejected/$reviewedOid/post-merge-reconciliation"
    if (Test-Path -LiteralPath $rejectedRoot) {
        throw 'A post-merge reconciliation already exists; inspect the retained evidence before another state change.'
    }
    New-Item -ItemType Directory -Path $rejectedRoot -Force | Out-Null
    Copy-FileWithHeartbeat -SourcePath ([string]$State.statePath) -DestinationPath (Join-Path $rejectedRoot 'state.before.json')
    $ownerPath = Get-ModReservationOwnerPath -ModLockPath ([string]$State.modLockPath) -Repository ([string]$State.repositoryRoot)
    Copy-FileWithHeartbeat -SourcePath $ownerPath -DestinationPath (Join-Path $rejectedRoot 'reservation-owner.before.json')
    $diffBytes = Get-ModUpdateGitOutputBytes -WorkingDirectory ([string]$State.repositoryRoot) -Arguments @('diff', '--binary', '--no-ext-diff', '--no-renames', "$reviewedOid..$mergedHeadOid", '--')
    $nameStatusBytes = Get-ModUpdateGitOutputBytes -WorkingDirectory ([string]$State.repositoryRoot) -Arguments @('diff', '--name-status', '--no-renames', "$reviewedOid..$mergedHeadOid", '--')
    Write-AtomicBytes -Path (Join-Path $rejectedRoot 'reviewed-f-to-merged-head.diff') -Bytes $diffBytes
    Write-AtomicBytes -Path (Join-Path $rejectedRoot 'reviewed-f-to-merged-head.name-status.txt') -Bytes $nameStatusBytes
    Write-AtomicJson -Path (Join-Path $rejectedRoot 'merge-fingerprint.json') -Value $Fingerprint

    $fingerprintPath = Join-Path ([string]$State.artifactsRoot) 'merge-fingerprint.json'
    Write-AtomicJson -Path $fingerprintPath -Value $Fingerprint
    $reconciliationPath = Join-Path ([string]$State.artifactsRoot) 'post-merge-reconciliation.json'
    $record = [ordered]@{
        schemaVersion = 1
        kind = 'post-merge-fingerprint-reconciliation'
        runId = [string]$State.runId
        observedAt = Get-UtcTimestamp
        reviewedOid = $reviewedOid
        mergedHeadOid = $mergedHeadOid
        mergeCommitOid = [string]$PullRequest.mergeCommit.oid
        originMainOid = $OriginMainOid
        pullRequest = $PullRequest
        fingerprint = [ordered]@{ path = $fingerprintPath; sha256 = Get-FileSha256 -Path $fingerprintPath }
        rejectedEvidencePath = $rejectedRoot
        reviewedToMergedDiffSha256 = Get-Sha256Bytes -Bytes $diffBytes
        reviewedToMergedNameStatusSha256 = Get-Sha256Bytes -Bytes $nameStatusBytes
        outcome = 'The merged source fingerprint is recorded. The prior Candidate Gate and Review are superseded because the merged PR head differs from reviewed F; exact run resources remain available for user-selected append-only recovery.'
    }
    Write-AtomicJson -Path $reconciliationPath -Value $record
    Write-AtomicJson -Path (Join-Path $rejectedRoot 'post-merge-reconciliation.json') -Value $record
    Write-AtomicJson -Path (Join-Path $rejectedRoot 'manifest.json') -Value ([ordered]@{
        schemaVersion = 1
        runId = [string]$State.runId
        generatedAt = Get-UtcTimestamp
        files = Get-ModUpdateEvidenceManifest -Root $rejectedRoot
    })

    $null = Set-ModUpdateChangedHeadState -State $State -PullRequest $PullRequest -OriginMainOid $OriginMainOid `
        -FingerprintSha256 (Get-FileSha256 -Path $fingerprintPath) -ReconciliationPath $reconciliationPath `
        -ReconciliationSha256 (Get-FileSha256 -Path $reconciliationPath)
    Suspend-Stage -State $State -Context $Stage -Result 'waiting-user' `
        -ArtifactSha256 (Get-FileSha256 -Path $reconciliationPath) -OutputStage 'post-merge-reconciliation' -Data $record
}

function Invoke-ModUpdateMergeTopologyReconciliation {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $PullRequest,
        [Parameter(Mandatory)][Collections.IDictionary] $Fingerprint,
        [Parameter(Mandatory)][string] $OriginMainOid,
        [Parameter(Mandatory)][Collections.IDictionary] $Stage
    )
    $fingerprintPath = Join-Path ([string]$State.artifactsRoot) 'merge-fingerprint.json'
    Write-AtomicJson -Path $fingerprintPath -Value $Fingerprint
    $reconciliationPath = Join-Path ([string]$State.artifactsRoot) 'merge-topology-reconciliation.json'
    if (Test-Path -LiteralPath $reconciliationPath) {
        throw 'A merge-topology reconciliation already exists; inspect the retained evidence before another state change.'
    }
    $record = [ordered]@{
        schemaVersion = 1
        kind = 'merge-topology-reconciliation'
        runId = [string]$State.runId
        observedAt = Get-UtcTimestamp
        reviewedOid = [string]$State.reviewedOid
        mergedHeadOid = [string]$PullRequest.headRefOid
        mergeCommitOid = [string]$PullRequest.mergeCommit.oid
        originMainOid = $OriginMainOid
        pullRequest = $PullRequest
        fingerprint = [ordered]@{ path = $fingerprintPath; sha256 = Get-FileSha256 -Path $fingerprintPath }
        outcome = 'The source fingerprint matches merged main, while the reviewed head is not an ancestor of the reported merge commit. Prior Gate and Review evidence is superseded; exact run resources remain available for user-selected reconciliation.'
    }
    Write-AtomicJson -Path $reconciliationPath -Value $record

    Set-MergeStateValue -State $State -Name 'status' -Value 'waiting-user'
    Set-MergeStateValue -State $State -Name 'waitingReason' -Value ([ordered]@{
        code = 'merge_topology_requires_reconciliation'
        message = 'The reported merge uses a topology that cannot prove reviewed F by ancestry. The verified fingerprint and merge tuple are retained for user-selected reconciliation.'
        reconciliationPath = $reconciliationPath
    })
    Set-MergeStateValue -State $State -Name 'headOid' -Value ([string]$PullRequest.headRefOid)
    Set-MergeStateValue -State $State -Name 'mergedHeadOid' -Value ([string]$PullRequest.headRefOid)
    Set-MergeStateValue -State $State -Name 'mergeCommitOid' -Value ([string]$PullRequest.mergeCommit.oid)
    Set-MergeStateValue -State $State -Name 'mergedAt' -Value ([string]$PullRequest.mergedAt)
    Set-MergeStateValue -State $State -Name 'originMainOid' -Value $OriginMainOid
    Set-MergeStateValue -State $State -Name 'mergeFingerprintSha256' -Value (Get-FileSha256 -Path $fingerprintPath)
    Set-MergeStateValue -State $State -Name 'mergeTopologyReconciliation' -Value ([ordered]@{
        path = $reconciliationPath
        sha256 = Get-FileSha256 -Path $reconciliationPath
    })
    Set-MergeStateValue -State $State -Name 'reviewedOid' -Value $null
    Set-MergeStateValue -State $State -Name 'localReview' -Value $null
    Set-MergeStateValue -State $State -Name 'reviewSnapshot' -Value $null
    Set-MergeStateValue -State $State -Name 'lastError' -Value $null
    $State.completedStages = @($State.completedStages | Where-Object { $_ -notin @('validate', 'publish', 'review-snapshot', 'finalize-merge') })
    $State.candidateGate = [ordered]@{ status = 'not-run' }

    Suspend-Stage -State $State -Context $Stage -Result 'waiting-user' `
        -ArtifactSha256 (Get-FileSha256 -Path $reconciliationPath) -OutputStage 'merge-topology-reconciliation' -Data $record
}

function Invoke-ModUpdateReviewedHeadFinalization {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $PullRequest,
        [Parameter(Mandatory)][Collections.IDictionary] $Fingerprint,
        [Parameter(Mandatory)][string] $OriginMainOid,
        [AllowNull()][Collections.IDictionary] $Stage
    )
    $repository = [IO.Path]::GetFullPath([string]$State.repositoryRoot)
    $runId = [string]$State.runId
    $reviewedOid = [string]$State.reviewedOid
    $worktree = [IO.Path]::GetFullPath([string]$State.worktreePath)
    $archiveLocations = Get-ModUpdateArchiveLocations -State $State
    $sourceArchive = [string]$archiveLocations.sourcePath
    $finishedRoot = [string]$archiveLocations.finishedRoot
    $evidenceRoot = Join-Path $finishedRoot '.evidence'
    $evidenceFinal = Join-Path $evidenceRoot $runId
    $evidencePending = Join-Path $evidenceRoot ".pending-$runId"
    $finalEvidenceExists = Test-Path -LiteralPath $evidenceFinal -PathType Container
    if (Test-Path -LiteralPath $worktree -PathType Container) {
        $worktreeStatus = (Invoke-Git -WorkingDirectory $worktree -Arguments @('status', '--porcelain=v2', '--untracked-files=all')).output
        if (-not [string]::IsNullOrWhiteSpace($worktreeStatus)) { throw 'Run worktree must be clean before merge finalization.' }
        $worktreeHead = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $worktreeTree = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        if ($worktreeHead -cne $reviewedOid -or $worktreeTree -cne [string]$State.evidenceChain.fTreeOid) {
            throw 'Run worktree no longer points to the reviewed F/tree.'
        }
    }
    elseif (-not $finalEvidenceExists) { throw 'Run worktree is missing before final evidence was archived.' }

    foreach ($path in @($finishedRoot, $evidenceRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $null = Assert-NoReparsePath -Path $path -Root $repository -Label 'Finalization archive root'
    }
    if ($finalEvidenceExists) {
        $null = Assert-ModUpdateFinalEvidence -EvidencePath $evidenceFinal -RunId $runId
        $stageResult = Get-CompletedStageResult -State $State -Name 'finalize-merge'
    }
    if (-not $finalEvidenceExists) {
    if (Test-Path -LiteralPath $evidencePending) {
        $retained = Join-Path $evidenceRoot ".retained-$runId-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N'))"
        [IO.Directory]::Move($evidencePending, $retained)
    }
    New-Item -ItemType Directory -Path $evidencePending | Out-Null
    Write-AtomicJson -Path (Join-Path $evidencePending '.run-owner.json') -Value ([ordered]@{ schemaVersion = 1; runId = $runId; statePath = [string]$State.statePath })

    $mergeEvidence = [ordered]@{
        schemaVersion = 1
        runId = $runId
        reviewedOid = $reviewedOid
        originMainOid = $OriginMainOid
        verifiedAt = Get-UtcTimestamp
        pullRequest = $PullRequest
    }
    $mergeEvidencePath = Join-Path ([string]$State.artifactsRoot) 'merge-evidence.json'
    $mergeFingerprintPath = Join-Path ([string]$State.artifactsRoot) 'merge-fingerprint.json'
    Write-AtomicJson -Path $mergeEvidencePath -Value $mergeEvidence
    Write-AtomicJson -Path $mergeFingerprintPath -Value $Fingerprint
    Set-MergeStateValue -State $State -Name 'status' -Value 'merged'
    Set-MergeStateValue -State $State -Name 'waitingReason' -Value $null
    Set-MergeStateValue -State $State -Name 'mergedAt' -Value ([string]$PullRequest.mergedAt)
    Set-MergeStateValue -State $State -Name 'mergeCommitOid' -Value ([string]$PullRequest.mergeCommit.oid)
    Set-MergeStateValue -State $State -Name 'mergedHeadOid' -Value $reviewedOid
    Set-MergeStateValue -State $State -Name 'originMainOid' -Value $OriginMainOid
    Set-MergeStateValue -State $State -Name 'mergeEvidenceSha256' -Value (Get-FileSha256 -Path $mergeEvidencePath)
    Set-MergeStateValue -State $State -Name 'mergeFingerprintSha256' -Value (Get-FileSha256 -Path $mergeFingerprintPath)
    Set-MergeStateValue -State $State -Name 'lastError' -Value $null
    $stageArtifactPath = Join-Path ([string]$State.artifactsRoot) 'merge-finalization.json'
    if (@($State.completedStages) -contains 'finalize-merge') {
        $stageResult = Get-CompletedStageResult -State $State -Name 'finalize-merge'
    }
    else {
        if (-not $Stage) { throw 'A new merge finalization requires an active stage context.' }
        Write-AtomicJson -Path $stageArtifactPath -Value ([ordered]@{
            schemaVersion = 1; runId = $runId; disposition = 'merge-verified-cleanup-pending'
            pullRequest = $PullRequest; fingerprint = $Fingerprint; verifiedAt = Get-UtcTimestamp
        })
        $stageResult = Complete-Stage -State $State -Context $Stage -ArtifactSha256 (Get-FileSha256 -Path $stageArtifactPath) -Data ([ordered]@{
            prUrl = [string]$State.prUrl; reviewedOid = $reviewedOid; fingerprintPath = [string]$Fingerprint.repositoryPath
        })
    }

    Copy-ModUpdateEvidenceTree -Source ([string]$State.artifactsRoot) -Destination (Join-Path $evidencePending 'artifacts')
    Copy-ModUpdateEvidenceTree -Source (Join-Path ([string]$State.runRoot) 'review-artifacts') -Destination (Join-Path $evidencePending 'review-artifacts')
    $supporting = Join-Path $evidencePending 'supporting'
    New-Item -ItemType Directory -Path $supporting -Force | Out-Null
    foreach ($item in @(
        [ordered]@{ source = [string]$State.statePath; name = 'state-merged.json' },
        [ordered]@{ source = [string]$State.claimPath; name = 'claim.json' },
        [ordered]@{ source = (Get-ModReservationOwnerPath -ModLockPath ([string]$State.modLockPath) -Repository $repository); name = 'reservation-owner.json' }
    )) {
        Copy-FileWithHeartbeat -SourcePath $item.source -DestinationPath (Join-Path $supporting $item.name)
    }
    Write-AtomicJson -Path (Join-Path $evidencePending 'state-final.json') -Value ([ordered]@{
        schemaVersion = 1
        disposition = 'merge-evidence-archived'
        archivedAt = Get-UtcTimestamp
        runId = $runId
        mod = [string]$State.mod
        archive = [ordered]@{
            filename = [string]$State.archive.filename
            size = [int64]$State.archive.size
            sha256 = [string]$State.archive.sha256
            finishedPath = Join-Path $finishedRoot ([string]$State.archive.filename)
        }
        branch = [ordered]@{ name = [string]$State.branch; tip = $reviewedOid; tree = [string]$State.evidenceChain.fTreeOid }
        pullRequest = $mergeEvidence
        mergeFingerprint = $Fingerprint
        evidenceChain = $State.evidenceChain
        candidateGate = $State.candidateGate
        localReview = $State.localReview
        stageTimings = $State.stageTimings
    })
    $archiveFiles = Get-ModUpdateEvidenceManifest -Root $evidencePending
    Write-AtomicJson -Path (Join-Path $evidencePending 'archive-manifest.json') -Value ([ordered]@{
        schemaVersion = 1; generatedAt = Get-UtcTimestamp; runId = $runId; files = $archiveFiles
    })
    [IO.Directory]::Move($evidencePending, $evidenceFinal)
    foreach ($entry in $archiveFiles) {
        $archivedPath = Assert-ContainedPath -Candidate (Join-Path $evidenceFinal ([string]$entry.path)) -Root $evidenceFinal -Label 'Archived finalization evidence'
        $null = Assert-MergeFileTuple -Path $archivedPath -Size ([int64]$entry.size) -Sha256 ([string]$entry.sha256)
    }
    }

    $finishedArchive = [string]$archiveLocations.finishedPath
    $sourceLease = $null
    try {
        $sourceLease = Enter-SharedCoordinationLock -Repository $repository -ResourceKey 'source-acquisition' -ActualRunId $runId -ReceiptRoot $evidenceFinal
        if (Test-Path -LiteralPath $sourceArchive -PathType Leaf) {
            $null = Assert-MergeFileTuple -Path $sourceArchive -Size ([int64]$State.archive.size) -Sha256 ([string]$State.archive.sha256)
            if (Test-Path -LiteralPath $finishedArchive -PathType Leaf) {
                $null = Assert-MergeFileTuple -Path $finishedArchive -Size ([int64]$State.archive.size) -Sha256 ([string]$State.archive.sha256)
                [IO.File]::Delete($sourceArchive)
                $archiveDisposition = 'deduplicated-same-name-same-sha'
            }
            else {
                [IO.File]::Move($sourceArchive, $finishedArchive)
                $archiveDisposition = 'moved-to-finished'
            }
        }
        elseif (Test-Path -LiteralPath $finishedArchive -PathType Leaf) {
            $null = Assert-MergeFileTuple -Path $finishedArchive -Size ([int64]$State.archive.size) -Sha256 ([string]$State.archive.sha256)
            $archiveDisposition = 'already-in-finished'
        }
        else { throw 'Finalization cannot find the immutable archive for archival.' }
    }
    finally { if ($sourceLease) { $null = Exit-SharedCoordinationLock -Lease $sourceLease } }
    $null = Assert-MergeFileTuple -Path $finishedArchive -Size ([int64]$State.archive.size) -Sha256 ([string]$State.archive.sha256)

    $registeredWorktree = (Invoke-Git -WorkingDirectory $repository -Arguments @('worktree', 'list', '--porcelain')).output
    $worktreeRegistered = Test-ModUpdateWorktreeRegistered -Porcelain $registeredWorktree -ExpectedPath $worktree
    if (Test-Path -LiteralPath $worktree -PathType Container) {
        if (-not $worktreeRegistered) { throw 'Exact run worktree is not registered with Git.' }
        $null = Invoke-Git -WorkingDirectory $repository -Arguments @('worktree', 'remove', '--', $worktree)
        if (Test-Path -LiteralPath $worktree) { throw 'Exact run worktree remains after standard removal.' }
    }
    elseif ($worktreeRegistered) { throw 'Git still registers the missing exact run worktree.' }
    $localRef = "refs/heads/$($State.branch)"
    $localRefResult = Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', '--verify', '--quiet', $localRef) -AllowFailure
    if ($localRefResult.exitCode -eq 0) {
        $localOid = $localRefResult.output.Trim()
        if ($localOid -cne $reviewedOid) { throw 'Local run branch changed before atomic deletion.' }
        $null = Invoke-Git -WorkingDirectory $repository -Arguments @('update-ref', '-d', $localRef, $reviewedOid)
    }
    $remoteRef = "refs/heads/$($State.branch)"
    $remoteListing = Invoke-Git -WorkingDirectory $repository -Arguments @('ls-remote', '--heads', [string]$State.remote, $remoteRef)
    if (-not [string]::IsNullOrWhiteSpace($remoteListing.output)) {
        $remoteOid = $remoteListing.output.Split("`t")[0]
        if ($remoteOid -cne $reviewedOid) { throw 'Remote run branch changed before deletion.' }
        $remoteLease = "--force-with-lease=${remoteRef}:$reviewedOid"
        $null = Invoke-Git -WorkingDirectory $repository -Arguments @('push', [string]$State.remote, $remoteLease, ":$remoteRef")
    }
    $remoteAfter = Invoke-Git -WorkingDirectory $repository -Arguments @('ls-remote', '--heads', [string]$State.remote, $remoteRef)
    if (-not [string]::IsNullOrWhiteSpace($remoteAfter.output)) { throw 'Remote run branch remains after deletion.' }

    $lockRoot = Split-Path -Parent ([string]$State.modLockPath)
    $claimRoot = Join-Path $repository 'AI Auto Update/.claims'
    $inProgressRoot = Join-Path $repository 'AI Auto Update/In Progress'
    $claimDirectory = Split-Path -Parent ([string]$State.claimPath)
    $owner = Read-ActiveReservationOwner
    if ([string]$owner.runId -cne $runId -or [string]$owner.modLockKey -cne [string]$State.modLockKey) {
        throw 'Reservation owner changed before terminal release.'
    }
    Suspend-ModReservationWorker -State $State
    Exit-RunWriterLock -Lease $script:writerLease
    $script:writerLease = $null
    if (Test-Path -LiteralPath $claimDirectory -PathType Container) {
        Remove-ModUpdateOwnedTree -Path $claimDirectory -Root $claimRoot -Label 'Finalized claim directory'
    }
    $releasedTombstone = Join-Path $lockRoot ".released-$($State.modLockKey)-$runId"
    if (Test-Path -LiteralPath $releasedTombstone) { throw 'Reservation release tombstone already exists.' }
    [IO.Directory]::Move([string]$State.modLockPath, $releasedTombstone)
    Remove-ModUpdateOwnedTree -Path $releasedTombstone -Root $lockRoot -Label 'Released reservation tombstone'
    if (Test-Path -LiteralPath ([string]$State.runRoot) -PathType Container) {
        Remove-ModUpdateOwnedTree -Path ([string]$State.runRoot) -Root $inProgressRoot -Label 'Finalized run root'
    }

    [ordered]@{
        result = 'passed'
        runId = $runId
        stage = 'finalize-merge'
        status = 'merged-and-finalized'
        statePath = [string]$State.statePath
        stageTimings = $stageResult.stageTimings
        artifactSha256 = Get-FileSha256 -Path (Join-Path $evidenceFinal 'artifacts/merge-finalization.json')
        data = [ordered]@{
            prUrl = [string]$State.prUrl
            mergeCommitOid = [string]$PullRequest.mergeCommit.oid
            reviewedOid = $reviewedOid
            originMainOid = $OriginMainOid
            fingerprintPath = [string]$Fingerprint.repositoryPath
            fingerprintBlobOid = [string]$Fingerprint.fingerprintBlobOid
            fingerprintArtifactSha256 = [string]$State.mergeFingerprintSha256
            fingerprintBlobSha256 = [string]$Fingerprint.fingerprintBlobSha256
            archiveSha256 = [string]$State.archive.sha256
            finishedArchive = $finishedArchive
            archiveDisposition = $archiveDisposition
            evidencePath = $evidenceFinal
            reservationReleased = $true
        }
    }
}

function Invoke-ModUpdateMergeFinalization {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    if ([string]$State.status -ceq 'waiting-user' -and $State.Contains('postMergeReconciliation') -and $State.postMergeReconciliation) {
        $path = Assert-NoReparsePath -Path ([string]$State.postMergeReconciliation.path) -Root ([string]$State.repositoryRoot) -Label 'Post-merge reconciliation'
        if ((Get-FileSha256 -Path $path) -cne [string]$State.postMergeReconciliation.sha256) {
            throw 'Post-merge reconciliation receipt changed after it was recorded.'
        }
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$record.runId -cne [string]$State.runId -or [string]$record.kind -cne 'post-merge-fingerprint-reconciliation') {
            throw 'Post-merge reconciliation receipt belongs to a different run or contract.'
        }
        return [ordered]@{
            result = 'waiting-user'; idempotent = $true; runId = [string]$State.runId
            stage = 'post-merge-reconciliation'; status = [string]$State.status; statePath = [string]$State.statePath
            artifactSha256 = [string]$State.postMergeReconciliation.sha256; data = $record
        }
    }
    if ([string]$State.status -ceq 'waiting-user' -and $State.Contains('mergeTopologyReconciliation') -and $State.mergeTopologyReconciliation) {
        $path = Assert-NoReparsePath -Path ([string]$State.mergeTopologyReconciliation.path) -Root ([string]$State.repositoryRoot) -Label 'Merge-topology reconciliation'
        if ((Get-FileSha256 -Path $path) -cne [string]$State.mergeTopologyReconciliation.sha256) {
            throw 'Merge-topology reconciliation receipt changed after it was recorded.'
        }
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$record.runId -cne [string]$State.runId -or [string]$record.kind -cne 'merge-topology-reconciliation') {
            throw 'Merge-topology reconciliation receipt belongs to a different run or contract.'
        }
        return [ordered]@{
            result = 'waiting-user'; idempotent = $true; runId = [string]$State.runId
            stage = 'merge-topology-reconciliation'; status = [string]$State.status; statePath = [string]$State.statePath
            artifactSha256 = [string]$State.mergeTopologyReconciliation.sha256; data = $record
        }
    }
    $stage = if (@($State.completedStages) -contains 'finalize-merge') { $null } else { Start-Stage -Name 'finalize-merge' }
    $reviewedOid = Assert-ModUpdateMergeFinalizationState -State $State
    $pr = (Invoke-Gh -WorkingDirectory ([string]$State.repositoryRoot) -Arguments @(
        'pr', 'view', [string]$State.prNumber, '--json', 'number,url,state,isDraft,mergedAt,mergeCommit,headRefName,headRefOid,baseRefName'
    )).output | ConvertFrom-Json -AsHashtable
    if ([int]$pr.number -ne [int]$State.prNumber -or [string]$pr.url -cne [string]$State.prUrl -or
        [string]$pr.headRefName -cne [string]$State.branch -or [string]$pr.baseRefName -cne [string]$State.pullRequestBase -or
        [bool]$pr.isDraft) {
        throw 'Observed PR identity, draft state, base, or head branch differs from the published run tuple.'
    }
    if ([string]$pr.headRefOid -notmatch '^[0-9a-f]{40}$') { throw 'Observed PR head OID is missing or invalid.' }
    $disposition = Get-MergeFinalizationDisposition -PullRequestState ([string]$pr.state) `
        -ReviewedOid $reviewedOid -ObservedHeadOid ([string]$pr.headRefOid)
    if ($disposition -ceq 'open-head-changed-after-review') {
        Set-MergeStateValue -State $State -Name 'status' -Value 'waiting-user'
        Set-MergeStateValue -State $State -Name 'observedPrHeadOid' -Value ([string]$pr.headRefOid)
        Set-MergeStateValue -State $State -Name 'waitingReason' -Value ([ordered]@{
            code = 'open_head_changed_after_review'
            message = 'The open pull request head differs from reviewed F. The reviewed tuple and exact run evidence remain available for a fresh append-only Review.'
            reviewedOid = $reviewedOid
            observedHeadOid = [string]$pr.headRefOid
        })
        $observation = Write-ModUpdateMergeObservation -State $State -PullRequest $pr -Disposition $disposition
        return (Suspend-Stage -State $State -Context $stage -Result 'waiting-user' -ArtifactSha256 $observation.sha256 `
            -OutputStage 'merge-finalization' -Data ([ordered]@{ disposition = $disposition; observationPath = $observation.path; prUrl = [string]$State.prUrl }))
    }
    if ($disposition -in @('awaiting-merge', 'closed-without-merge')) {
        if ($disposition -ceq 'closed-without-merge') {
            Set-MergeStateValue -State $State -Name 'status' -Value 'waiting-user'
            Set-MergeStateValue -State $State -Name 'waitingReason' -Value ([ordered]@{
                code = 'pull_request_closed_without_merge'
                message = 'The pull request is closed without a merge. The run reservation and evidence remain available for a user-selected recovery.'
            })
        }
        else {
            Set-MergeStateValue -State $State -Name 'status' -Value 'awaiting-user-merge'
            Set-MergeStateValue -State $State -Name 'waitingReason' -Value $null
            Set-MergeStateValue -State $State -Name 'observedPrHeadOid' -Value $null
        }
        $observation = Write-ModUpdateMergeObservation -State $State -PullRequest $pr -Disposition $disposition
        return (Suspend-Stage -State $State -Context $stage -Result 'waiting-user' -ArtifactSha256 $observation.sha256 `
            -OutputStage 'merge-finalization' -Data ([ordered]@{ disposition = $disposition; observationPath = $observation.path; prUrl = [string]$State.prUrl }))
    }
    if (-not $pr.mergeCommit -or [string]$pr.mergeCommit.oid -notmatch '^[0-9a-f]{40}$' -or
        [string]::IsNullOrWhiteSpace([string]$pr.mergedAt)) {
        throw 'Merged PR evidence is missing its head, merge commit, or merge timestamp.'
    }

    $repository = [string]$State.repositoryRoot
    $remote = [string]$State.remote
    $base = [string]$State.pullRequestBase
    $temporaryRef = "refs/darktide-finalization/$($State.runId)/pr-head"
    try {
        $null = Invoke-Git -WorkingDirectory $repository -Arguments @('fetch', $remote, "+refs/heads/${base}:refs/remotes/${remote}/${base}")
        $null = Invoke-Git -WorkingDirectory $repository -Arguments @('fetch', $remote, "+refs/pull/$($State.prNumber)/head:$temporaryRef")
        $observedHead = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', $temporaryRef)).output.Trim()
        if ($observedHead -cne [string]$pr.headRefOid) { throw 'Fetched PR head differs from the GitHub merge observation.' }
        $originMainOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', "refs/remotes/$remote/$base")).output.Trim()
        $mergeInMain = Invoke-Git -WorkingDirectory $repository -Arguments @('merge-base', '--is-ancestor', [string]$pr.mergeCommit.oid, $originMainOid) -AllowFailure
        if ($mergeInMain.exitCode -ne 0) { throw 'Observed merge commit is not reachable from the recorded remote main branch.' }
        $fingerprint = Get-ModUpdateFingerprintRecord -State $State -CommitOid ([string]$pr.headRefOid) `
            -OriginMainOid $originMainOid -PullRequest $pr
        $headInMerge = Invoke-Git -WorkingDirectory $repository -Arguments @('merge-base', '--is-ancestor', [string]$pr.headRefOid, [string]$pr.mergeCommit.oid) -AllowFailure
        if ($headInMerge.exitCode -ne 0) {
            return (Invoke-ModUpdateMergeTopologyReconciliation -State $State -PullRequest $pr -Fingerprint $fingerprint `
                -OriginMainOid $originMainOid -Stage $stage)
        }
        if ($disposition -ceq 'reconcile-changed-head') {
            return (Invoke-ModUpdateChangedHeadReconciliation -State $State -PullRequest $pr -Fingerprint $fingerprint `
                -OriginMainOid $originMainOid -Stage $stage)
        }
        Invoke-ModUpdateReviewedHeadFinalization -State $State -PullRequest $pr -Fingerprint $fingerprint `
            -OriginMainOid $originMainOid -Stage $stage
    }
    finally {
        $resolvedTemporary = Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', '--verify', '--quiet', $temporaryRef) -AllowFailure
        if ($resolvedTemporary.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedTemporary.output)) {
            $null = Invoke-Git -WorkingDirectory $repository -Arguments @('update-ref', '-d', $temporaryRef, $resolvedTemporary.output.Trim())
        }
    }
}
