#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('claim', 'verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot', 'run')]
    [string] $Command,

    [Parameter(Mandatory)]
    [string] $RepositoryRoot,

    [string] $StatePath,
    [string] $ArchivePath,
    [string] $ModDirectory,
    [string] $RunId,
    [string] $LocalizationPlanPath,
    [string] $LocalReviewPath,
    [string[]] $MetadataPath = @(),
    [string] $BaseRef = 'origin/main',
    [string] $WorktreeParent,
    [string] $Remote = 'origin',
    [string] $PullRequestBase = 'main',
    [ValidateSet('awaiting-user-merge')]
    [string] $Until = 'awaiting-user-merge',
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-SafeSlug {
    param([Parameter(Mandatory)][string] $Value)
    $slug = ($Value.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-' -replace '-{2,}', '-').Trim('.', '-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'MOD identity cannot be converted to a safe slug.'
    }
    $slug
}

function Assert-ContainedPath {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Root,
        [string] $Label = 'path'
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the allowed root."
    }
    $candidateFull
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    $json = $Value | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Read-State {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "State file does not exist: $Path"
    }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Save-State {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $State.updatedAt = Get-UtcTimestamp
    Write-AtomicJson -Path ([string]$State.statePath) -Value $State
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start Git.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $stdoutTask.Result.TrimEnd()
    $warning = $stderrTask.Result.TrimEnd()
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed ($exitCode): $warning $output"
    }
    [pscustomobject]@{
        exitCode = $exitCode
        output = $output
        warning = $warning
    }
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start GitHub CLI.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $result = [ordered]@{
        exitCode = $process.ExitCode
        output = $stdoutTask.Result.TrimEnd()
        warning = $stderrTask.Result.TrimEnd()
    }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) {
        throw "gh $($Arguments -join ' ') failed ($($result.exitCode)): $($result.warning) $($result.output)"
    }
    $result
}

function Get-GitBlobBytes {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $Object
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start git cat-file.' }
    $memory = [IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "git cat-file failed: $errorText" }
    $memory.ToArray()
}

function New-Manifest {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $Kind = 'files'
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    $files = @(
        Get-ChildItem -LiteralPath $rootFull -File -Recurse |
            ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($rootFull, $_.FullName).Replace('\', '/')
                [ordered]@{
                    path = $relative
                    size = $_.Length
                    sha256 = Get-FileSha256 -Path $_.FullName
                }
            } |
            Sort-Object { $_.path }
    )
    $manifest = [ordered]@{
        schemaVersion = 1
        kind = $Kind
        root = $rootFull
        generatedAt = Get-UtcTimestamp
        files = $files
    }
    Write-AtomicJson -Path $OutputPath -Value $manifest
    [ordered]@{ path = $OutputPath; sha256 = Get-FileSha256 -Path $OutputPath; fileCount = $files.Count }
}

function Test-CrlfNormalizationOnly {
    param([byte[]] $RawBytes, [byte[]] $IndexedBytes)
    $normalized = [IO.MemoryStream]::new()
    for ($index = 0; $index -lt $RawBytes.LongLength; $index++) {
        if ($RawBytes[$index] -eq 13 -and ($index + 1) -lt $RawBytes.LongLength -and $RawBytes[$index + 1] -eq 10) {
            continue
        }
        $normalized.WriteByte($RawBytes[$index])
    }
    $candidate = $normalized.ToArray()
    if ($candidate.LongLength -ne $IndexedBytes.LongLength) { return $false }
    for ($index = 0; $index -lt $candidate.LongLength; $index++) {
        if ($candidate[$index] -ne $IndexedBytes[$index]) { return $false }
    }
    $true
}

function Get-StageArtifactPath {
    param([Collections.IDictionary] $State, [string] $Name)
    switch ($Name) {
        'claim' { Join-Path ([string]$State.runRoot) 'claim.json' }
        'verify-source' { Join-Path ([string]$State.artifactsRoot) 'archive-listing.json' }
        'extract' { if ($State.extractionManifest) { [string]$State.extractionManifest.path } }
        'install' { if ($State.rawInstallManifest) { [string]$State.rawInstallManifest.path } }
        'localization' { [string]$State.localizationManifestPath }
        'build-commits' { if ($State.evidenceReceipt) { [string]$State.evidenceReceipt.path } }
        'validate' { if ($State.candidateGate) { [string]$State.candidateGate.validationReportPath } }
        'publish' { Join-Path ([string]$State.artifactsRoot) 'publication.json' }
        'review-snapshot' { Join-Path ([string]$State.artifactsRoot) 'review-completion-validation.json' }
    }
}

function New-GitNormalizationManifest {
    param([Collections.IDictionary] $State)
    $records = @()
    foreach ($file in Get-ChildItem -LiteralPath $State.installRoot -File -Recurse | Sort-Object FullName) {
        $relativeToRepository = [IO.Path]::GetRelativePath($State.worktreePath, $file.FullName).Replace('\', '/')
        $relativeToMod = [IO.Path]::GetRelativePath($State.installRoot, $file.FullName).Replace('\', '/')
        $rawBytes = [IO.File]::ReadAllBytes($file.FullName)
        $blobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relativeToRepository", '--', $file.FullName)).output.Trim()
        $indexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $blobOid
        $transform = if ((Get-Sha256Bytes -Bytes $rawBytes) -eq (Get-Sha256Bytes -Bytes $indexedBytes)) { 'none' }
            elseif (Test-CrlfNormalizationOnly -RawBytes $rawBytes -IndexedBytes $indexedBytes) { 'crlf-to-lf' }
            else { throw "Git clean processing changed bytes beyond CRLF-to-LF for $relativeToRepository." }
        $records += [ordered]@{
            path = $relativeToMod
            repositoryPath = $relativeToRepository
            rawSize = $rawBytes.LongLength
            rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
            indexedSize = $indexedBytes.LongLength
            indexedSha256 = Get-Sha256Bytes -Bytes $indexedBytes
            blobOid = $blobOid
            transform = $transform
            whitespacePreserved = $true
        }
    }
    $path = Join-Path $State.artifactsRoot 'git-index-normalization.json'
    Write-AtomicJson -Path $path -Value ([ordered]@{
        schemaVersion = 1
        mode = 'git-add-autocrlf-v1'
        gitVersion = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('--version')).output
        coreAutocrlf = $true
        files = $records
    })
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path; fileCount = $records.Count }
}

function New-GitTreeManifest {
    param([Collections.IDictionary] $State, [string] $CommitOid)
    $listing = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.quotePath=false', 'ls-tree', '-r', '-l', '--full-tree', $CommitOid, '--', $State.modRelativePath)).output
    $files = @()
    foreach ($line in @($listing -split "`r?`n" | Where-Object { $_ })) {
        if ($line -notmatch '^[0-7]{6} blob ([0-9a-f]{40})\s+(\d+)\t(.+)$') { throw "Unable to parse candidate Git tree entry: $line" }
        $repositoryPath = $Matches[3]
        $relative = $repositoryPath.Substring(([string]$State.modRelativePath).Length).TrimStart('/')
        $bytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $Matches[1]
        if ($bytes.LongLength -ne [int64]$Matches[2]) { throw "Candidate Git blob size mismatch: $repositoryPath" }
        $files += [ordered]@{
            path = $relative
            repositoryPath = $repositoryPath
            blobOid = $Matches[1]
            size = $bytes.LongLength
            sha256 = Get-Sha256Bytes -Bytes $bytes
        }
    }
    $path = Join-Path $State.artifactsRoot 'candidate-tree-manifest.json'
    Write-AtomicJson -Path $path -Value ([ordered]@{
        schemaVersion = 1
        kind = 'candidate-git-tree'
        commitOid = $CommitOid
        treeOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', "$CommitOid^{tree}")).output.Trim()
        files = @($files | Sort-Object { $_.path })
    })
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path; fileCount = $files.Count }
}

function Start-Stage {
    param([string] $Name)
    [ordered]@{
        name = $Name
        startedAt = Get-UtcTimestamp
        stopwatch = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-Stage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][string] $ArtifactSha256,
        [Collections.IDictionary] $Data = @{}
    )
    $Context.stopwatch.Stop()
    $name = [string]$Context.name
    if (-not $State.Contains('stageTimings')) { $State.stageTimings = [ordered]@{} }
    if (-not $State.Contains('completedStages')) { $State.completedStages = @() }
    $previousAttempt = if ($State.stageTimings.Contains($name)) { [int]$State.stageTimings[$name].attempt } else { 0 }
    $timing = [ordered]@{
        attempt = $previousAttempt + 1
        startedAt = $Context.startedAt
        completedAt = Get-UtcTimestamp
        activeMilliseconds = $Context.stopwatch.ElapsedMilliseconds
        waitingMilliseconds = 0
        result = 'passed'
        artifactSha256 = $ArtifactSha256
    }
    $State.stageTimings[$name] = $timing
    $State.completedStages = @($State.completedStages | Where-Object { $_ -ne $name }) + $name
    Save-State -State $State
    [ordered]@{
        result = 'passed'
        runId = $State.runId
        stage = $name
        status = $State.status
        statePath = $State.statePath
        stageTimings = $timing
        artifactSha256 = $ArtifactSha256
        data = $Data
    }
}

function Get-CompletedStageResult {
    param([Collections.IDictionary] $State, [string] $Name)
    if (@($State.completedStages) -contains $Name) {
        Assert-LockOwner -State $State
        $artifactPath = Get-StageArtifactPath -State $State -Name $Name
        if ([string]::IsNullOrWhiteSpace($artifactPath) -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Completed stage $Name is missing its recorded artifact. Same-run recovery must stop instead of silently reusing it."
        }
        $expectedSha = [string]$State.stageTimings[$Name].artifactSha256
        if ((Get-FileSha256 -Path $artifactPath) -ne $expectedSha) {
            throw "Completed stage $Name artifact SHA-256 no longer matches its receipt."
        }
        if ($Name -in @('build-commits', 'validate', 'publish', 'review-snapshot')) {
            $head = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
            if ($head -ne $State.evidenceChain.fOid) { throw "Completed stage $Name no longer points at immutable F." }
        }
        return [ordered]@{
            result = 'passed'
            idempotent = $true
            runId = $State.runId
            stage = $Name
            status = $State.status
            statePath = $State.statePath
            stageTimings = $State.stageTimings[$Name]
            artifactSha256 = $State.stageTimings[$Name].artifactSha256
            data = [ordered]@{ recovery = 'same run completed stage and artifact receipt verified' }
        }
    }
    $null
}

function Assert-LockOwner {
    param([Collections.IDictionary] $State)
    $ownerPath = Join-Path ([string]$State.modLockPath) 'owner.json'
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { throw 'MOD identity lock owner is missing.' }
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
    if ($owner.runId -ne $State.runId -or $owner.modLockKey -ne $State.modLockKey -or $owner.statePath -ne $State.statePath) {
        throw 'MOD identity lock does not belong to this same run tuple.'
    }
}

function Test-RunWriterOwnerActive {
    param([Collections.IDictionary] $Owner)
    if ($Owner.machineName -cne [Environment]::MachineName -or -not $Owner.processId -or -not $Owner.processStartTicks) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$Owner.processId) -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().Ticks -eq [int64]$Owner.processStartTicks
    }
    catch { return $false }
}

function Enter-RunWriterLock {
    param([Collections.IDictionary] $State)
    Assert-LockOwner -State $State
    $lockPath = Join-Path ([string]$State.runRoot) '.writer.lock'
    $token = [guid]::NewGuid().ToString()
    $owner = [ordered]@{
        schemaVersion = 1
        runId = $State.runId
        statePath = $State.statePath
        token = $token
        machineName = [Environment]::MachineName
        processId = $PID
        processStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        acquiredAt = Get-UtcTimestamp
    }
    $ownerBytes = [Text.UTF8Encoding]::new($false).GetBytes(($owner | ConvertTo-Json -Depth 10))

    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.Write($ownerBytes, 0, $ownerBytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            return [ordered]@{ path = $lockPath; token = $token }
        }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { continue }
            try { $existing = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable }
            catch { $existing = [ordered]@{} }
            if (Test-RunWriterOwnerActive -Owner $existing) {
                throw 'Another process is the active single writer for this run state.'
            }

            $recoveryRoot = Join-Path ([string]$State.artifactsRoot) 'writer-lock-recovery'
            New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
            $retainedPath = Join-Path $recoveryRoot ("stale-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N')).json")
            try { [IO.File]::Move($lockPath, $retainedPath) }
            catch [IO.IOException] { continue }
            $State.lastRecovery = [ordered]@{
                at = Get-UtcTimestamp
                reason = 'stale run writer lock retained'
                retainedPath = $retainedPath
            }
            Save-State -State $State
        }
    }
    throw 'Unable to acquire the single-writer lock for this run state.'
}

function Exit-RunWriterLock {
    param([Collections.IDictionary] $Lease)
    if (-not $Lease) { return }
    if (-not (Test-Path -LiteralPath $Lease.path -PathType Leaf)) {
        throw 'Run writer lock disappeared before its owner released it.'
    }
    $owner = Get-Content -LiteralPath $Lease.path -Raw | ConvertFrom-Json -AsHashtable
    if ($owner.token -cne $Lease.token) { throw 'Run writer lock ownership changed before release.' }
    [IO.File]::Delete([string]$Lease.path)
}

function Complete-IncompleteClaim {
    param([Collections.IDictionary] $State)
    Assert-LockOwner -State $State
    $stage = Start-Stage -Name 'claim'
    $isRecovery = -not [string]::IsNullOrWhiteSpace([string]$State.claimAttemptedAt)
    $State.claimAttemptedAt = Get-UtcTimestamp
    Save-State -State $State
    $repository = [string]$State.repositoryRoot
    $worktree = [string]$State.worktreePath
    $worktreeParent = Split-Path -Parent $worktree
    New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null

    if (Test-Path -LiteralPath $worktree -PathType Container) {
        $head = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $branch = (Invoke-Git -WorkingDirectory $worktree -Arguments @('branch', '--show-current')).output.Trim()
        if ($head -ne $State.baseOid -or $branch -cne $State.branch) {
            throw 'Incomplete claim worktree does not match its immutable base and branch tuple.'
        }
    }
    else {
        $branchExists = (Invoke-Git -WorkingDirectory $repository -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$($State.branch)") -AllowFailure).exitCode -eq 0
        $arguments = if ($branchExists) {
            @('worktree', 'add', $worktree, [string]$State.branch)
        }
        else {
            @('worktree', 'add', '-b', [string]$State.branch, $worktree, [string]$State.baseOid)
        }
        $null = Invoke-Git -WorkingDirectory $repository -Arguments $arguments
    }

    $coordinatorArchive = [string]$State.claimCoordinatorArchivePath
    $claimedArchive = [string]$State.archive.path
    if (Test-Path -LiteralPath $coordinatorArchive -PathType Leaf) {
        if (Test-Path -LiteralPath $claimedArchive) { throw 'Incomplete claim has both coordinator and run-owned archive copies.' }
        [IO.File]::Move($coordinatorArchive, $claimedArchive)
    }
    if (-not (Test-Path -LiteralPath $claimedArchive -PathType Leaf) -or (Get-FileSha256 -Path $claimedArchive) -ne $State.archive.sha256) {
        throw 'Incomplete claim archive is missing or no longer matches its source SHA-256.'
    }

    $ownerPath = Join-Path ([string]$State.modLockPath) 'owner.json'
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
    $owner.worktree = $State.worktreePath
    $owner.heartbeat = Get-UtcTimestamp
    Write-AtomicJson -Path $ownerPath -Value $owner

    $claimRecord = Get-Content -LiteralPath $State.claimPath -Raw | ConvertFrom-Json -AsHashtable
    $claimRecord.status = 'worktree-ready'
    $claimRecord.statePath = $State.statePath
    $claimRecord.archive = $State.archive
    Write-AtomicJson -Path $State.claimPath -Value $claimRecord
    $runClaimPath = Join-Path ([string]$State.runRoot) 'claim.json'
    Write-AtomicJson -Path $runClaimPath -Value $claimRecord
    $State.status = 'worktree-ready'
    $State.lastRecovery = if ($isRecovery) {
        [ordered]@{ at = Get-UtcTimestamp; reason = 'incomplete claim reattached to original run tuple'; retainedPath = $State.claimPath }
    }
    else { $State.lastRecovery }
    $claimSha = Get-FileSha256 -Path $runClaimPath
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $claimSha -Data ([ordered]@{ branch = $State.branch; worktreePath = $worktree })
}

function Invoke-Claim {
    if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        $existing = Read-State -Path ([IO.Path]::GetFullPath($StatePath))
        if ($RunId -and $existing.runId -ne [guid]::Parse($RunId).ToString()) { throw 'Existing state belongs to another run.' }
        if ($ModDirectory -and $existing.repoModDirectory -cne $ModDirectory) { throw 'Existing state belongs to another MOD identity.' }
        if ([IO.Path]::GetFullPath($RepositoryRoot) -ne [IO.Path]::GetFullPath([string]$existing.repositoryRoot)) {
            throw 'Existing state belongs to another repository.'
        }
        $completed = Get-CompletedStageResult -State $existing -Name 'claim'
        if ($completed) { return $completed }
        return Complete-IncompleteClaim -State $existing
    }
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or [string]::IsNullOrWhiteSpace($ModDirectory)) {
        throw 'claim requires -ArchivePath and -ModDirectory.'
    }
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $queueRoot = Join-Path $repository 'AI Auto Update'
    $sourceFull = Assert-ContainedPath -Candidate $ArchivePath -Root $queueRoot -Label 'Archive path'
    if ((Split-Path -Parent $sourceFull) -ne [IO.Path]::GetFullPath($queueRoot)) {
        throw 'Archive must be a direct child of AI Auto Update.'
    }
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) { throw 'Archive is missing.' }

    $sampleOne = Get-Item -LiteralPath $sourceFull
    [Threading.Thread]::Sleep(10000)
    $sampleTwo = Get-Item -LiteralPath $sourceFull
    if ($sampleOne.Length -ne $sampleTwo.Length -or $sampleOne.LastWriteTimeUtc -ne $sampleTwo.LastWriteTimeUtc) {
        throw 'Archive did not remain stable across the required ten-second observation.'
    }

    $actualRunId = if ($RunId) { [guid]::Parse($RunId).ToString() } else { [guid]::NewGuid().ToString() }
    $slug = ConvertTo-SafeSlug -Value $ModDirectory
    $short = $actualRunId.Replace('-', '').Substring(0, 8)
    $runRoot = Join-Path (Join-Path $queueRoot 'In Progress') "$slug-$short"
    $actualStatePath = if ($StatePath) { Assert-ContainedPath -Candidate $StatePath -Root $runRoot -Label 'State path' } else { Join-Path $runRoot 'state.json' }
    if (Test-Path -LiteralPath $actualStatePath -PathType Leaf) {
        $existing = Read-State -Path $actualStatePath
        if ($existing.runId -ne $actualRunId) { throw 'Existing state belongs to another run.' }
        $completed = Get-CompletedStageResult -State $existing -Name 'claim'
        if ($completed) { return $completed }
        return Complete-IncompleteClaim -State $existing
    }

    $archiveSha = Get-FileSha256 -Path $sourceFull
    $integrityScript = Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1'
    $integrity = & $integrityScript -PassThru
    if ($integrity.result -ne 'passed') { throw 'The packaged Schema 14 Workflow and Review Baseline failed integrity validation.' }

    $claimRoot = Join-Path (Join-Path $queueRoot '.claims') $actualRunId
    $claimSourceRoot = Join-Path $claimRoot 'source'
    $claimPath = Join-Path $claimRoot 'claim.json'
    $coordinatorArchive = Join-Path $claimSourceRoot ([IO.Path]::GetFileName($sourceFull))
    $modRelativePath = "Warhammer 40,000 DARKTIDE/mods/$ModDirectory"
    $lockKey = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant()))
    $lockRoot = Join-Path $queueRoot 'In Progress/.locks/mod'
    New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
    $modLockPath = Join-Path $lockRoot "$lockKey.lock"
    try { New-Item -ItemType Directory -Path $modLockPath -ErrorAction Stop | Out-Null }
    catch { throw 'Another generation already owns this canonical MOD identity.' }

    $plannedOwner = [ordered]@{
        runId = $actualRunId
        workflowCommitOid = $integrity.sourceCommit
        modLockKey = $lockKey
        canonicalModRelativePath = $modRelativePath
        sourceSha256 = $archiveSha
        claimPath = [IO.Path]::GetFullPath($claimPath)
        plannedStatePath = [IO.Path]::GetFullPath($actualStatePath)
        statePath = [IO.Path]::GetFullPath($actualStatePath)
        workerId = $PID
        leaseMode = 'active'
        acquiredAt = Get-UtcTimestamp
        heartbeat = Get-UtcTimestamp
        worktree = $null
    }
    Write-AtomicJson -Path (Join-Path $modLockPath 'owner.json') -Value $plannedOwner
    New-Item -ItemType Directory -Path $claimSourceRoot -Force | Out-Null
    [IO.File]::Move($sourceFull, $coordinatorArchive)
    $claimRecord = [ordered]@{
        runId = $actualRunId
        status = 'identified'
        workflowCommitOid = $integrity.sourceCommit
        workflowSha256 = $integrity.workflow.sha256
        reviewBaselineSha256 = $integrity.reviewBaseline.sha256
        createdAt = Get-UtcTimestamp
        waitingReason = $null
        repoModDirectory = $ModDirectory
        modLockKey = $lockKey
        canonicalModRelativePath = $modRelativePath
        plannedStatePath = [IO.Path]::GetFullPath($actualStatePath)
        archive = [ordered]@{
            filename = [IO.Path]::GetFileName($coordinatorArchive)
            originalPath = $sourceFull
            path = [IO.Path]::GetFullPath($coordinatorArchive)
            size = $sampleTwo.Length
            sha256 = $archiveSha
            format = 'zip'
        }
    }
    Write-AtomicJson -Path $claimPath -Value $claimRecord

    New-Item -ItemType Directory -Path (Join-Path $runRoot 'source') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'staging') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'artifacts') -Force | Out-Null
    $claimedArchive = Join-Path (Join-Path $runRoot 'source') ([IO.Path]::GetFileName($sourceFull))

    $baseOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', '--verify', "$BaseRef^{commit}")).output.Trim()
    $baseTreeOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', "$baseOid^{tree}")).output.Trim()
    $branch = "Update/$slug/$([DateTimeOffset]::Now.ToString('yyyyMMdd'))-$short"
    $worktreeParent = if ([string]::IsNullOrWhiteSpace($WorktreeParent)) {
        Join-Path (Split-Path -Parent $repository) ((Split-Path -Leaf $repository) + '-worktrees')
    }
    else { [IO.Path]::GetFullPath($WorktreeParent) }
    New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null
    $worktree = Join-Path $worktreeParent "$slug-$short"
    $state = [ordered]@{
        schemaVersion = 14
        runId = $actualRunId
        status = 'claiming'
        statePath = [IO.Path]::GetFullPath($actualStatePath)
        repositoryRoot = $repository
        runRoot = [IO.Path]::GetFullPath($runRoot)
        artifactsRoot = [IO.Path]::GetFullPath((Join-Path $runRoot 'artifacts'))
        mod = $ModDirectory
        modSlug = $slug
        repoModDirectory = $ModDirectory
        modRelativePath = $modRelativePath
        modLockKey = $lockKey
        modLockPath = [IO.Path]::GetFullPath($modLockPath)
        claimPath = [IO.Path]::GetFullPath($claimPath)
        claimCoordinatorArchivePath = [IO.Path]::GetFullPath($coordinatorArchive)
        branch = $branch
        worktreePath = [IO.Path]::GetFullPath($worktree)
        baseRef = $BaseRef
        remote = $Remote
        pullRequestBase = $PullRequestBase
        baseOid = $baseOid
        checkedMainOid = $baseOid
        metadataPaths = @($MetadataPath)
        workflowRef = $integrity.sourceRef
        workflowCommitOid = $integrity.sourceCommit
        workflowPath = $integrity.workflow.originalPath
        workflowBlobOid = $integrity.workflow.gitBlobOid
        workflowSha256 = $integrity.workflow.sha256
        reviewBaselinePath = $integrity.reviewBaseline.originalPath
        reviewBaselineBlobOid = $integrity.reviewBaseline.gitBlobOid
        reviewBaselineSha256 = $integrity.reviewBaseline.sha256
        referenceSources = @(
            [ordered]@{ role = 'workflow'; path = $integrity.workflow.originalPath; blobOid = $integrity.workflow.gitBlobOid; sha256 = $integrity.workflow.sha256 },
            [ordered]@{ role = 'review-baseline'; path = $integrity.reviewBaseline.originalPath; blobOid = $integrity.reviewBaseline.gitBlobOid; sha256 = $integrity.reviewBaseline.sha256 }
        )
        archive = [ordered]@{
            filename = [IO.Path]::GetFileName($claimedArchive)
            path = [IO.Path]::GetFullPath($claimedArchive)
            size = $sampleTwo.Length
            sha256 = $archiveSha
            format = 'zip'
        }
        completedStages = @()
        stageTimings = [ordered]@{}
        lastRecovery = $null
        evidenceChain = [ordered]@{
            c0Oid = $baseOid
            c0TreeOid = $baseTreeOid
            c1ParentOid = $null
            c1ParentTreeOid = $null
            c1Oid = $null
            c1TreeOid = $null
            c1EmptyReason = $null
            c2Status = 'not-run'
            c2Reason = $null
            c2ParentOid = $null
            c2ParentTreeOid = $null
            c2Oid = $null
            c2TreeOid = $null
            c3Status = 'not-run'
            c3Reason = $null
            c3ParentOid = $null
            c3ParentTreeOid = $null
            c3Oid = $null
            c3TreeOid = $null
            fOid = $null
            fTreeOid = $null
        }
        candidateGate = [ordered]@{ status = 'not-run' }
        localizationMode = 'none'
        localizationFiles = @()
        evidenceTargetPaths = @()
        evidenceTargetPathsSha256 = $null
        evidenceGeneration = 1
        prNumber = $null
        prUrl = $null
        published = $false
        externalReview = [ordered]@{ status = 'not-requested'; pollingWaitSeconds = 0 }
        securityOverrides = @()
        createdAt = Get-UtcTimestamp
        updatedAt = Get-UtcTimestamp
        claimAttemptedAt = $null
    }
    Write-AtomicJson -Path $state.statePath -Value $state
    Complete-IncompleteClaim -State $state
}

function Get-ZipEntries {
    param([Parameter(Mandatory)][string] $Path)
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries = @()
        $totalLength = [int64]0
        if ($archive.Entries.Count -gt 100000) { throw 'Archive entry count exceeds the 100,000 entry limit.' }
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName.Replace('\', '/')
            $segments = @($entryPath.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
            if ([IO.Path]::IsPathRooted($entryPath) -or $entryPath.StartsWith('/') -or $entryPath.Contains(':') -or $segments -contains '..' -or $entryPath.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
                throw "Archive path traversal or rooted path rejected: $entryPath"
            }
            if ($segments.Count -eq 0) { continue }
            foreach ($segment in $segments) {
                if ($segment.EndsWith(' ') -or $segment.EndsWith('.')) { throw "Windows path collision rejected: $entryPath" }
            }
            $collisionKey = $entryPath.Normalize([Text.NormalizationForm]::FormC)
            if (-not $seen.Add($collisionKey)) { throw "Duplicate or Unicode/case-colliding archive path rejected: $entryPath" }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000) { throw "Archive symlink rejected: $entryPath" }
            $totalLength += $entry.Length
            if ($entry.Length -gt 1GB -or $totalLength -gt 4GB -or ($entry.CompressedLength -gt 0 -and ($entry.Length / $entry.CompressedLength) -gt 1000)) {
                throw "Archive expansion limit rejected: $entryPath"
            }
            if (-not $entryPath.EndsWith('/')) {
                try {
                    $probe = $entry.Open()
                    try { $null = $probe.ReadByte() } finally { $probe.Dispose() }
                }
                catch { throw "Encrypted or unreadable archive entry rejected: $entryPath. $($_.Exception.Message)" }
            }
            $entries += [ordered]@{
                path = $entryPath
                size = $entry.Length
                compressedSize = $entry.CompressedLength
                externalAttributes = $entry.ExternalAttributes
                directory = $entryPath.EndsWith('/')
            }
        }
        [ordered]@{ archive = $archive; stream = $stream; entries = $entries }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Invoke-VerifySource {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'verify-source'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'verify-source'
    Assert-LockOwner -State $State
    $archivePath = [string]$State.archive.path
    if ((Get-FileSha256 -Path $archivePath) -ne $State.archive.sha256) { throw 'Claimed archive SHA-256 changed.' }
    $zip = Get-ZipEntries -Path $archivePath
    try {
        $fileEntries = @($zip.entries | Where-Object { -not $_.directory })
        if ($fileEntries.Count -eq 0) { throw 'Archive contains no files.' }
        $roots = @($fileEntries | ForEach-Object { $_.path.Split('/')[0] } | Sort-Object -Unique)
        if ($roots.Count -ne 1 -or $roots[0] -cne $State.repoModDirectory) {
            throw 'Invalid archive root; exactly one root matching the canonical MOD directory is required.'
        }
        $listing = [ordered]@{
            schemaVersion = 1
            archiveSha256 = $State.archive.sha256
            root = $roots[0]
            entries = @($zip.entries | Sort-Object { $_.path })
            verifiedAt = Get-UtcTimestamp
        }
        $path = Join-Path $State.artifactsRoot 'archive-listing.json'
        Write-AtomicJson -Path $path -Value $listing
        $State.archive.format = 'zip'
        Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $path) -Data ([ordered]@{ listingPath = $path; entryCount = $listing.entries.Count })
    }
    finally {
        $zip.archive.Dispose()
        $zip.stream.Dispose()
    }
}

function Invoke-Extract {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'extract'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'extract'
    Assert-LockOwner -State $State
    $stagingRoot = Join-Path $State.runRoot 'staging'
    $temporaryRoot = Join-Path $stagingRoot ('.extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $zip = Get-ZipEntries -Path $State.archive.path
    try {
        foreach ($entry in $zip.archive.Entries) {
            $relative = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $destination = Assert-ContainedPath -Candidate (Join-Path $temporaryRoot $relative) -Root $temporaryRoot -Label 'Archive entry'
            if ($relative.EndsWith('/')) {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                continue
            }
            $parent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $input = $entry.Open()
            $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    }
    finally {
        $zip.archive.Dispose()
        $zip.stream.Dispose()
    }
    $reparse = Get-ChildItem -LiteralPath $temporaryRoot -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    if ($reparse) { throw 'Extracted symlink or reparse point rejected.' }
    $finalRoot = Join-Path $stagingRoot 'extracted'
    if (Test-Path -LiteralPath $finalRoot) {
        $recoveryPath = Join-Path $stagingRoot ('recovery-' + [guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $finalRoot -Destination $recoveryPath
        $State.lastRecovery = [ordered]@{ at = Get-UtcTimestamp; reason = 'incomplete extract replaced'; retainedPath = $recoveryPath }
    }
    [IO.Directory]::Move($temporaryRoot, $finalRoot)
    $manifestPath = Join-Path $State.artifactsRoot 'extraction-manifest.json'
    $manifest = New-Manifest -Root $finalRoot -OutputPath $manifestPath -Kind 'extraction'
    $State.extractionRoot = [IO.Path]::GetFullPath($finalRoot)
    $State.extractionManifest = $manifest
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $manifest.sha256 -Data $manifest
}

function Copy-DirectoryBytes {
    param([string] $Source, [string] $Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($directory in Get-ChildItem -LiteralPath $Source -Directory -Recurse) {
        $relative = [IO.Path]::GetRelativePath($Source, $directory.FullName)
        New-Item -ItemType Directory -Path (Join-Path $Destination $relative) -Force | Out-Null
    }
    foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.File]::Copy($file.FullName, $target, $false)
    }
}

function Invoke-Install {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'install'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'install'
    Assert-LockOwner -State $State
    $source = Join-Path $State.extractionRoot $State.repoModDirectory
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Verified archive root is missing from extraction staging.' }
    $modsRoot = Join-Path $State.worktreePath 'Warhammer 40,000 DARKTIDE/mods'
    $target = Assert-ContainedPath -Candidate (Join-Path $modsRoot $State.repoModDirectory) -Root $modsRoot -Label 'MOD install path'
    if (Test-Path -LiteralPath $target) {
        $resolvedTarget = [IO.Path]::GetFullPath($target)
        $resolvedMods = [IO.Path]::GetFullPath($modsRoot) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTarget.StartsWith($resolvedMods, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing broad install deletion.' }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    }
    Copy-DirectoryBytes -Source $source -Destination $target
    $reparse = Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    if ($reparse) { throw 'Installed reparse point rejected.' }
    $rawPath = Join-Path $State.artifactsRoot 'raw-install-manifest.json'
    $installPath = Join-Path $State.artifactsRoot 'install-manifest.json'
    $raw = New-Manifest -Root $target -OutputPath $rawPath -Kind 'raw-install'
    $install = New-Manifest -Root $target -OutputPath $installPath -Kind 'install'
    $State.installRoot = $target
    $State.rawInstallManifest = $raw
    $State.installManifest = $install
    $State.gitIndexNormalization = New-GitNormalizationManifest -State $State
    $State.status = 'installed'
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $raw.sha256 -Data ([ordered]@{ rawInstall = $raw; install = $install })
}

function Write-ByteFile {
    param([string] $Path, [byte[]] $Bytes)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Invoke-ApprovedSpans {
    param([byte[]] $IndexedBytes, [object[]] $ApprovedSpans)
    $result = $IndexedBytes
    $orderedSpans = @($ApprovedSpans | Sort-Object { [int64]$_.startByte } -Descending)
    $nextStart = $IndexedBytes.LongLength
    foreach ($span in $orderedSpans) {
        $start = [int64]$span.startByte
        $length = [int64]$span.length
        if ($start -lt 0 -or $length -lt 0 -or ($start + $length) -gt $IndexedBytes.LongLength -or ($start + $length) -gt $nextStart) {
            throw 'Approved localization byte spans overlap or escape the indexed base.'
        }
        $oldBytes = [byte[]]::new($length)
        [Array]::Copy($IndexedBytes, $start, $oldBytes, 0, $length)
        if ((Get-Sha256Bytes -Bytes $oldBytes) -ne [string]$span.oldSha256) { throw 'Approved span oldSha256 does not match indexed bytes.' }
        $replacement = [Convert]::FromBase64String([string]$span.replacementBase64)
        $memory = [IO.MemoryStream]::new()
        if ($start -gt 0) { $memory.Write($result, 0, $start) }
        $memory.Write($replacement, 0, $replacement.Length)
        $tailStart = $start + $length
        if ($tailStart -lt $result.LongLength) { $memory.Write($result, $tailStart, $result.LongLength - $tailStart) }
        $result = $memory.ToArray()
        $nextStart = $start
    }
    $result
}

function Invoke-Localization {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'localization'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'localization'
    Assert-LockOwner -State $State
    $plan = if ([string]::IsNullOrWhiteSpace($LocalizationPlanPath)) {
        [ordered]@{ schemaVersion = 1; mode = 'none'; files = @(); metadataPaths = @($State.metadataPaths) }
    }
    else {
        Get-Content -LiteralPath $LocalizationPlanPath -Raw | ConvertFrom-Json -AsHashtable
    }
    if ($plan.mode -notin @('none', 'zh-tw')) { throw 'Localization plan mode must be none or zh-tw.' }
    if ($plan.mode -eq 'none' -and @($plan.files).Count -ne 0) { throw 'Localization mode none cannot contain files.' }
    $removedPaths = if ($plan.Contains('removedPaths')) { @($plan.removedPaths) } else { @() }
    if ($plan.mode -eq 'none' -and $removedPaths.Count -ne 0) { throw 'Localization mode none cannot contain removed paths.' }
    foreach ($removedPath in $removedPaths) {
        $removedRelative = ([string]$removedPath).Replace('\', '/')
        if (-not $removedRelative.StartsWith($State.modRelativePath + '/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Removed localization target is outside the canonical MOD directory.'
        }
        $removedWorktreePath = Assert-ContainedPath -Candidate (Join-Path $State.worktreePath $removedRelative) -Root $State.worktreePath -Label 'Removed localization target'
        if (Test-Path -LiteralPath $removedWorktreePath) { throw 'A removed localization target still exists in the upstream install.' }
    }
    $localizationRoot = Join-Path $State.artifactsRoot 'localization'
    New-Item -ItemType Directory -Path $localizationRoot -Force | Out-Null
    $records = @()
    foreach ($file in @($plan.files)) {
        $relative = ([string]$file.relativePath).Replace('\', '/')
        if (-not $relative.StartsWith($State.modRelativePath + '/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Localization target is outside the canonical MOD directory.'
        }
        $worktreeFile = Assert-ContainedPath -Candidate (Join-Path $State.worktreePath $relative) -Root $State.worktreePath -Label 'Localization target'
        if (-not (Test-Path -LiteralPath $worktreeFile -PathType Leaf)) { throw 'Localization target file is missing.' }
        $rawBytes = [IO.File]::ReadAllBytes($worktreeFile)
        $blobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relative", '--', $worktreeFile)).output.Trim()
        $indexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $blobOid
        $indexedSha = Get-Sha256Bytes -Bytes $indexedBytes
        if ($indexedSha -ne [string]$file.indexedSha256) { throw 'Localization indexedSha256 does not match the Git-normalized source.' }
        $mergedBytes = Invoke-ApprovedSpans -IndexedBytes $indexedBytes -ApprovedSpans @($file.approvedSpans)
        $safeId = (Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($relative))).Substring(0, 16)
        $artifactDirectory = Join-Path $localizationRoot $safeId
        $oldObject = "$($State.evidenceChain.c0Oid):$relative"
        $oldExists = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('cat-file', '-e', $oldObject) -AllowFailure
        if ($oldExists.exitCode -eq 0) {
            Write-ByteFile -Path (Join-Path $artifactDirectory 'old.lua') -Bytes (Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $oldObject)
        }
        Write-ByteFile -Path (Join-Path $artifactDirectory 'new.lua') -Bytes $rawBytes
        Write-ByteFile -Path (Join-Path $artifactDirectory 'indexed.lua') -Bytes $indexedBytes
        Write-ByteFile -Path (Join-Path $artifactDirectory 'merged.lua') -Bytes $mergedBytes
        $decisionsPath = Join-Path $artifactDirectory 'decisions.json'
        Write-AtomicJson -Path $decisionsPath -Value $file
        $records += [ordered]@{
            relativePath = $relative
            safeId = $safeId
            rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
            indexedSha256 = $indexedSha
            mergedSha256 = Get-Sha256Bytes -Bytes $mergedBytes
            approvedSpans = @($file.approvedSpans)
            artifactDirectory = $artifactDirectory
            decisionsSha256 = Get-FileSha256 -Path $decisionsPath
        }
    }
    $manifestPath = Join-Path $State.artifactsRoot 'localization-manifest.json'
    Write-AtomicJson -Path $manifestPath -Value ([ordered]@{ schemaVersion = 1; mode = $plan.mode; files = $records; removedPaths = $removedPaths })
    $State.localizationMode = $plan.mode
    $State.localizationFiles = $records
    $State.localizationRemovedPaths = @($removedPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $State.evidenceTargetPaths = @(
        @($plan.files | ForEach-Object { @($(if ($_.Contains('oldRelativePath')) { [string]$_.oldRelativePath }), [string]$_.relativePath) }) + @($State.localizationRemovedPaths) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Replace('\', '/') } |
            Sort-Object -Unique
    )
    $targetPathJson = ConvertTo-Json -InputObject @($State.evidenceTargetPaths) -Compress
    $targetPathBytes = [Text.Encoding]::UTF8.GetBytes($targetPathJson)
    $State.evidenceTargetPathsSha256 = Get-Sha256Bytes -Bytes $targetPathBytes
    $State.localizationManifestPath = $manifestPath
    Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $manifestPath) -Data ([ordered]@{ mode = $plan.mode; fileCount = $records.Count })
}

function New-GitEvidenceFile {
    param([Collections.IDictionary] $State, [string] $Name, [string[]] $Arguments)
    $path = Join-Path (Join-Path $State.artifactsRoot 'git-evidence') $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $result = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments $Arguments
    [IO.File]::WriteAllText($path, $result.output + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path }
}

function Invoke-BuildCommits {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'build-commits'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'build-commits'
    Assert-LockOwner -State $State
    if ($State.published) { throw 'A published evidence branch is append-only; completed checkpoints are never reset or rebuilt in place.' }
    $worktree = [string]$State.worktreePath
    $targets = @($State.evidenceTargetPaths)
    $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('-c', 'core.autocrlf=true', 'add', '-A', '--', $State.modRelativePath)
    foreach ($target in $targets) {
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('reset', '--quiet', 'HEAD', '--', $target)
    }
    $c1Staged = Invoke-Git -WorkingDirectory $worktree -Arguments @('diff', '--cached', '--quiet') -AllowFailure
    if ($c1Staged.exitCode -eq 0 -and $State.localizationMode -eq 'none') { throw 'The archive is already current; an empty non-localization evidence commit is not allowed.' }
    if ($c1Staged.exitCode -notin @(0, 1)) { throw 'Unable to inspect the C1 index.' }
    $State.evidenceChain.c1ParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $State.evidenceChain.c1ParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
    $c1Arguments = @('commit', '-m', "chore($($State.modSlug)): sync upstream non-localization [C1]")
    if ($c1Staged.exitCode -eq 0) { $c1Arguments = @('commit', '--allow-empty', '-m', "chore($($State.modSlug)): sync upstream non-localization [C1]"); $State.evidenceChain.c1EmptyReason = 'active localization target contains the only upstream delta' }
    $null = Invoke-Git -WorkingDirectory $worktree -Arguments $c1Arguments
    $State.evidenceChain.c1Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $State.evidenceChain.c1TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()

    if ($State.localizationMode -eq 'zh-tw') {
        $State.evidenceChain.c2ParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $State.evidenceChain.c2ParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('-c', 'core.autocrlf=true', 'add', '-A', '--') + $targets)
        foreach ($record in $State.localizationFiles) {
            $indexObject = ":$([string]$record.relativePath)"
            $actualIndexed = Get-GitBlobBytes -WorkingDirectory $worktree -Object $indexObject
            if ((Get-Sha256Bytes -Bytes $actualIndexed) -ne $record.indexedSha256) { throw 'C2 index bytes do not match the immutable indexed localization artifact.' }
        }
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '--allow-empty', '-m', "chore($($State.modSlug)): checkpoint upstream localization [C2]")
        $State.evidenceChain.c2Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $State.evidenceChain.c2TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $State.evidenceChain.c2Status = 'committed'
        $State.evidenceChain.c3ParentOid = $State.evidenceChain.c2Oid
        $State.evidenceChain.c3ParentTreeOid = $State.evidenceChain.c2TreeOid
        foreach ($record in $State.localizationFiles) {
            $mergedPath = Join-Path ([string]$record.artifactDirectory) 'merged.lua'
            $destination = Assert-ContainedPath -Candidate (Join-Path $worktree ([string]$record.relativePath)) -Root $worktree -Label 'Merged localization target'
            Write-ByteFile -Path $destination -Bytes ([IO.File]::ReadAllBytes($mergedPath))
        }
        $c3Targets = @($State.localizationFiles | ForEach-Object { [string]$_.relativePath })
        if ($c3Targets.Count -ne 0) {
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('-c', 'core.autocrlf=true', 'add', '-A', '--') + $c3Targets)
        }
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '--allow-empty', '-m', "feat($($State.modSlug)): restore approved zh-tw localization [C3]")
        $State.evidenceChain.c3Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $State.evidenceChain.c3TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $State.evidenceChain.c3Status = 'committed'
    }
    else {
        $State.evidenceChain.c2Status = 'not-applicable'
        $State.evidenceChain.c2Reason = 'localization mode none'
        $State.evidenceChain.c3Status = 'not-applicable'
        $State.evidenceChain.c3Reason = 'localization mode none'
    }

    $metadataRecords = @()
    foreach ($metadataRelative in @($State.metadataPaths)) {
        $metadataNormalized = $metadataRelative.Replace('\', '/')
        if ($metadataNormalized -cne 'README.md' -and $metadataNormalized -cne ".hash/$($State.modSlug).hash") {
            throw 'Metadata allowlist permits only README.md and the current MOD hash file.'
        }
        $metadataFull = Assert-ContainedPath -Candidate (Join-Path $worktree $metadataRelative) -Root $worktree -Label 'Metadata path'
        if (-not (Test-Path -LiteralPath $metadataFull -PathType Leaf)) { throw "Metadata path is missing: $metadataRelative" }
        $metadataRecords += [ordered]@{ path = $metadataNormalized; sha256 = Get-FileSha256 -Path $metadataFull; size = (Get-Item -LiteralPath $metadataFull).Length }
    }
    $metadataPreviewPath = Join-Path $State.artifactsRoot 'metadata-preview.json'
    Write-AtomicJson -Path $metadataPreviewPath -Value ([ordered]@{ schemaVersion = 1; files = $metadataRecords; generatedAt = Get-UtcTimestamp })
    $State.metadataPreview = [ordered]@{ path = $metadataPreviewPath; sha256 = Get-FileSha256 -Path $metadataPreviewPath; fileCount = $metadataRecords.Count }
    if (@($State.metadataPaths).Count -gt 0) {
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('add', '--') + @($State.metadataPaths))
        $staged = Invoke-Git -WorkingDirectory $worktree -Arguments @('diff', '--cached', '--quiet') -AllowFailure
        if ($staged.exitCode -eq 1) {
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '-m', "docs($($State.modSlug)): update archive metadata [F]")
        }
        elseif ($staged.exitCode -ne 0) { throw 'Unable to inspect staged metadata.' }
    }
    $finalInstallManifestPath = Join-Path $State.artifactsRoot 'install-manifest.json'
    $State.installManifest = New-Manifest -Root $State.installRoot -OutputPath $finalInstallManifestPath -Kind 'install'
    $State.evidenceChain.fOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $State.evidenceChain.fTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
    $State.candidateOid = $State.evidenceChain.fOid
    $State.candidateTreeOid = $State.evidenceChain.fTreeOid
    $State.status = 'candidate-committed'

    $notApplicableEvidence = [ordered]@{ status = 'not-applicable'; path = $null; sha256 = 'not-applicable' }
    $evidence = [ordered]@{
        c1C2Diff = $notApplicableEvidence; c1C2NameStatus = $notApplicableEvidence
        c2C3Diff = $notApplicableEvidence; c2C3NameStatus = $notApplicableEvidence
        c3FDiff = $notApplicableEvidence; c3FNameStatus = $notApplicableEvidence
    }
    $evidence.c0C1Diff = New-GitEvidenceFile -State $State -Name 'c0-c1.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.c1Oid)")
    $evidence.c0C1NameStatus = New-GitEvidenceFile -State $State -Name 'c0-c1.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.c1Oid)")
    $evidence.c1ParentNameStatus = New-GitEvidenceFile -State $State -Name 'c1-parent.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c1ParentOid)..$($State.evidenceChain.c1Oid)")
    if ($State.localizationMode -eq 'zh-tw') {
        $evidence.c1C2Diff = New-GitEvidenceFile -State $State -Name 'c1-c2.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c1Oid)..$($State.evidenceChain.c2Oid)")
        $evidence.c1C2NameStatus = New-GitEvidenceFile -State $State -Name 'c1-c2.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c1Oid)..$($State.evidenceChain.c2Oid)")
        $evidence.c2C3Diff = New-GitEvidenceFile -State $State -Name 'c2-c3.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c2Oid)..$($State.evidenceChain.c3Oid)")
        $evidence.c2C3NameStatus = New-GitEvidenceFile -State $State -Name 'c2-c3.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c2Oid)..$($State.evidenceChain.c3Oid)")
        $evidence.c2ParentNameStatus = New-GitEvidenceFile -State $State -Name 'c2-parent.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c2ParentOid)..$($State.evidenceChain.c2Oid)")
        $evidence.c3ParentNameStatus = New-GitEvidenceFile -State $State -Name 'c3-parent.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c3ParentOid)..$($State.evidenceChain.c3Oid)")
        if ($State.evidenceChain.fOid -ne $State.evidenceChain.c3Oid) {
            $evidence.c3FDiff = New-GitEvidenceFile -State $State -Name 'c3-f.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c3Oid)..$($State.evidenceChain.fOid)")
            $evidence.c3FNameStatus = New-GitEvidenceFile -State $State -Name 'c3-f.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c3Oid)..$($State.evidenceChain.fOid)")
        }
    }
    $evidence.c0FDiff = New-GitEvidenceFile -State $State -Name 'c0-f.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.fOid)")
    $evidence.c0FNameStatus = New-GitEvidenceFile -State $State -Name 'c0-f.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.fOid)")
    $State.evidenceDiffs = $evidence
    $State.candidateTreeManifest = New-GitTreeManifest -State $State -CommitOid $State.evidenceChain.fOid
    $tuple = [ordered]@{ generation = $State.evidenceGeneration; chain = $State.evidenceChain; targetPathsSha256 = $State.evidenceTargetPathsSha256; archiveSha256 = $State.archive.sha256 }
    $tupleSha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $tuple -Depth 20 -Compress)))
    $receiptPath = Join-Path $State.artifactsRoot 'evidence-generation-receipt.json'
    Write-AtomicJson -Path $receiptPath -Value ([ordered]@{
        schemaVersion = 1; generation = $State.evidenceGeneration; runId = $State.runId; gitVersion = (Invoke-Git -WorkingDirectory $worktree -Arguments @('--version')).output; parameterVersion = 'full-index-binary-no-renames-v1'; inputTupleSha256 = $tupleSha; evidenceChain = $State.evidenceChain; candidateTreeManifest = $State.candidateTreeManifest; artifacts = $evidence; generatedAt = Get-UtcTimestamp
    })
    $State.evidenceReceipt = [ordered]@{ path = $receiptPath; sha256 = Get-FileSha256 -Path $receiptPath }
    $State.candidateGate = [ordered]@{ status = 'not-run' }
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $State.evidenceReceipt.sha256 -Data ([ordered]@{ evidenceChain = $State.evidenceChain; receipt = $State.evidenceReceipt })
}

function Invoke-Validate {
    param([Collections.IDictionary] $State)
    $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
    $validatorSha = Get-FileSha256 -Path $validator
    $recordedValidatorSha = if ($State.candidateGate.Contains('validatorSha256')) { [string]$State.candidateGate.validatorSha256 } else { $null }
    if (@($State.completedStages) -contains 'validate' -and $recordedValidatorSha -ne $validatorSha) {
        $State.completedStages = @($State.completedStages | Where-Object { $_ -ne 'validate' })
        $State.candidateGate.status = 'not-run'
        Save-State -State $State
    }
    $completed = Get-CompletedStageResult -State $State -Name 'validate'
    if ($completed -and $State.candidateGate.status -eq 'passed') { return $completed }
    $stage = Start-Stage -Name 'validate'
    $result = & $validator -StatePath $State.statePath -PassThru
    $State = Read-State -Path $State.statePath
    if ($result.result -ne 'passed') { throw 'Independent Final Candidate Gate rejected the candidate.' }
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $result.validationReportSha256 -Data ([ordered]@{ validationReportPath = $result.validationReportPath })
}

function Get-PrBody {
    param([Collections.IDictionary] $State)
    $localizationIds = @($State.localizationFiles | ForEach-Object { $_.safeId }) -join ', '
    if ([string]::IsNullOrWhiteSpace($localizationIds)) { $localizationIds = 'not-applicable' }
    $localizationEvidence = @($State.localizationFiles | ForEach-Object { "$($_.safeId): raw=$($_.rawSha256), indexed=$($_.indexedSha256), merged=$($_.mergedSha256), approved-spans=$(@($_.approvedSpans).Count)" }) -join '; '
    if ([string]::IsNullOrWhiteSpace($localizationEvidence)) { $localizationEvidence = 'not-applicable' }
    $approvedSpanCount = @($State.localizationFiles | ForEach-Object { @($_.approvedSpans).Count } | Measure-Object -Sum).Sum
    if ($null -eq $approvedSpanCount) { $approvedSpanCount = 0 }
    $unchangedTargetCount = @($State.localizationFiles | Where-Object { @($_.approvedSpans).Count -eq 0 }).Count
    $removedTargetCount = if ($State.Contains('localizationRemovedPaths')) { @($State.localizationRemovedPaths).Count } else { 0 }
    @"
## Darktide MOD update evidence

- Run: $($State.runId)
- MOD: $($State.mod)
- HEAD/F: $($State.evidenceChain.fOid)
- C0: $($State.evidenceChain.c0Oid)
- C1: $($State.evidenceChain.c1Oid)
- C2: $($State.evidenceChain.c2Oid) ($($State.evidenceChain.c2Status): $($State.evidenceChain.c2Reason))
- C3: $($State.evidenceChain.c3Oid) ($($State.evidenceChain.c3Status): $($State.evidenceChain.c3Reason))
- Trees C0/C1/C2/C3/F: $($State.evidenceChain.c0TreeOid) / $($State.evidenceChain.c1TreeOid) / $($State.evidenceChain.c2TreeOid) / $($State.evidenceChain.c3TreeOid) / $($State.evidenceChain.fTreeOid)
- Parent-tree Gate: C1^=$($State.evidenceChain.c1ParentTreeOid); C2^=$($State.evidenceChain.c2ParentTreeOid); C3^=$($State.evidenceChain.c3ParentTreeOid)
- C0..C1 diff/name-status SHA-256: $($State.evidenceDiffs.c0C1Diff.sha256) / $($State.evidenceDiffs.c0C1NameStatus.sha256)
- C1..C2 diff/name-status SHA-256: $($State.evidenceDiffs.c1C2Diff.sha256) / $($State.evidenceDiffs.c1C2NameStatus.sha256)
- C2..C3 diff/name-status SHA-256: $($State.evidenceDiffs.c2C3Diff.sha256) / $($State.evidenceDiffs.c2C3NameStatus.sha256)
- C0..F diff/name-status SHA-256: $($State.evidenceDiffs.c0FDiff.sha256) / $($State.evidenceDiffs.c0FNameStatus.sha256)
- C3..F diff/name-status SHA-256: $($State.evidenceDiffs.c3FDiff.sha256) / $($State.evidenceDiffs.c3FNameStatus.sha256)
- Evidence target paths SHA-256: $($State.evidenceTargetPathsSha256)
- Evidence target paths: $(@($State.evidenceTargetPaths) -join ', ')
- Extraction/raw-install/install/candidate-tree manifest SHA-256: $($State.extractionManifest.sha256) / $($State.rawInstallManifest.sha256) / $($State.installManifest.sha256) / $($State.candidateTreeManifest.sha256)
- Git normalization/metadata/evidence receipt SHA-256: $($State.gitIndexNormalization.sha256) / $($State.metadataPreview.sha256) / $($State.evidenceReceipt.sha256)
- Diff readability result/SHA-256: $($State.diffReadability.result) / $($State.diffReadability.sha256)
- Candidate Gate: $($State.candidateGate.status)
- Validation SHA-256: $($State.candidateGate.validationReportSha256)
- Workflow commit/SHA-256: $($State.workflowCommitOid) / $($State.workflowSha256)
- Review Baseline path/blob/SHA-256: $($State.reviewBaselinePath) / $($State.reviewBaselineBlobOid) / $($State.reviewBaselineSha256)
- Localization mode/ids: $($State.localizationMode) / $localizationIds
- Localization raw/indexed/merged evidence: $localizationEvidence
- Localization target/approved-span/unchanged/removed/BLOCKED counts: $(@($State.evidenceTargetPaths).Count) / $approvedSpanCount / $unchangedTargetCount / $removedTargetCount / 0
- Localization scope: only approved zh-tw spans; BLOCKED=0
- Archive filename/SHA-256: $($State.archive.filename) / $($State.archive.sha256)
- Security overrides: $(@($State.securityOverrides) -join ', ')
- External review: $($State.externalReview.status)
"@
}

function Invoke-Publish {
    param([Collections.IDictionary] $State)
    $currentBody = Get-PrBody -State $State
    $currentBodySha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($currentBody))
    if (@($State.completedStages) -contains 'publish') {
        $publicationPath = Join-Path $State.artifactsRoot 'publication.json'
        $publication = if (Test-Path -LiteralPath $publicationPath -PathType Leaf) { Get-Content -LiteralPath $publicationPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
        if (-not $publication -or -not $publication.Contains('prBodySha256') -or $publication.candidateGateSha256 -ne $State.candidateGate.validationReportSha256 -or $publication.prBodySha256 -ne $currentBodySha) {
            $State.completedStages = @($State.completedStages | Where-Object { $_ -ne 'publish' })
            Save-State -State $State
        }
    }
    $completed = Get-CompletedStageResult -State $State -Name 'publish'
    if ($completed) {
        $remoteHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('ls-remote', '--heads', $State.remote, "refs/heads/$($State.branch)")).output.Split("`t")[0]
        $pr = (Invoke-Gh -Arguments @('pr', 'view', [string]$State.prNumber, '--json', 'state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
        if ($remoteHead -ne $State.evidenceChain.fOid -or $pr.headRefOid -ne $remoteHead -or $pr.state -ne 'OPEN' -or $pr.isDraft) { throw 'Completed publication no longer has one open non-draft PR at immutable F.' }
        return $completed
    }
    $stage = Start-Stage -Name 'publish'
    Assert-LockOwner -State $State
    if ($State.candidateGate.status -ne 'passed') { throw 'Publishing requires a passed candidateGate.' }
    $head = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
    if ($head -ne $State.evidenceChain.fOid) { throw 'Local HEAD no longer equals F.' }
    $forbiddenPushOptions = @('--force', '--force-with-lease')
    if ($forbiddenPushOptions.Count -ne 2) { throw 'Append-only push guard is unavailable.' }
    $null = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('push', '--set-upstream', $Remote, $State.branch)
    $remoteHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('ls-remote', '--heads', $Remote, "refs/heads/$($State.branch)")).output.Split("`t")[0]
    if ($remoteHead -ne $head) { throw 'Remote branch does not equal F after append-only push.' }

    # Reuse an existing PR for this exact branch instead of creating duplicate PRs.
    $existingJson = (Invoke-Gh -Arguments @('pr', 'list', '--state', 'all', '--head', $State.branch, '--base', $State.pullRequestBase, '--json', 'number,url,state,isDraft,headRefOid')).output
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($existingJson)) {
        $parsedExisting = $existingJson | ConvertFrom-Json -AsHashtable
        $existing = @($parsedExisting)
    }
    $body = $currentBody
    if ($existing.Count -gt 1) { throw 'More than one existing PR matches the run branch.' }
    if ($existing.Count -eq 1) {
        if ($existing[0].state -ne 'OPEN') { throw 'The existing PR is closed; waiting for user recovery.' }
        $prNumber = [int]$existing[0].number
        $null = Invoke-Gh -Arguments @('pr', 'edit', [string]$prNumber, '--body', $body)
        $prUrl = [string]$existing[0].url
    }
    else {
        $prUrl = (Invoke-Gh -Arguments @('pr', 'create', '--base', $State.pullRequestBase, '--head', $State.branch, '--title', "Update $($State.mod)", '--body', $body)).output.Trim()
        $prNumber = [int]($prUrl.TrimEnd('/').Split('/')[-1])
    }
    $pr = (Invoke-Gh -Arguments @('pr', 'view', [string]$prNumber, '--json', 'number,url,state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
    if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $State.pullRequestBase -or $pr.headRefName -ne $State.branch -or $pr.headRefOid -ne $head) {
        throw 'Created or reused PR does not match the required open non-draft base/head/F tuple.'
    }
    $prUrl = [string]$pr.url
    $State.prNumber = $prNumber
    $State.prUrl = $prUrl
    $State.headOid = $head
    $State.published = $true
    $State.status = 'pr-open'
    $artifactPath = Join-Path $State.artifactsRoot 'publication.json'
    Write-AtomicJson -Path $artifactPath -Value ([ordered]@{ prNumber = $prNumber; prUrl = $prUrl; headOid = $head; remoteHeadOid = $remoteHead; branch = $State.branch; base = $State.pullRequestBase; candidateGateSha256 = $State.candidateGate.validationReportSha256; prBodySha256 = $currentBodySha; publishedAt = Get-UtcTimestamp })
    Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $artifactPath) -Data ([ordered]@{ prNumber = $prNumber; prUrl = $prUrl })
}

function Invoke-ReviewSnapshot {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'review-snapshot'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'review-snapshot'
    if (-not $State.prNumber) { throw 'review-snapshot requires an existing PR.' }
    if ([string]::IsNullOrWhiteSpace($LocalReviewPath) -or -not (Test-Path -LiteralPath $LocalReviewPath -PathType Leaf)) {
        throw 'review-snapshot requires -LocalReviewPath from an Agent review of the current F using the packaged Review Baseline.'
    }
    $localReview = Get-Content -LiteralPath $LocalReviewPath -Raw | ConvertFrom-Json -AsHashtable
    if ($localReview.result -ne 'passed' -or $localReview.headOid -ne $State.evidenceChain.fOid -or $localReview.candidateGateSha256 -ne $State.candidateGate.validationReportSha256) {
        throw 'Local Review does not pass and bind the current F/Candidate Gate tuple.'
    }
    if (@($localReview.securityBlocking).Count -ne 0) { throw 'Local Review contains a security-blocking finding.' }
    $unresolved = @($localReview.findings | Where-Object { $_.disposition -notin @('keep', 'resolved', 'out-of-scope') })
    if ($unresolved.Count -ne 0) { throw 'Local Review contains findings without disposition.' }
    $localReviewArtifactPath = Join-Path $State.artifactsRoot 'review.json'
    Write-AtomicJson -Path $localReviewArtifactPath -Value $localReview
    $State.localReview = [ordered]@{ path = $localReviewArtifactPath; sha256 = Get-FileSha256 -Path $localReviewArtifactPath; result = 'passed'; reviewedAt = $localReview.reviewedAt }
    $State.reviewedOid = $State.evidenceChain.fOid
    $State.status = 'reviewing'
    Save-State -State $State

    $snapshotAt = Get-UtcTimestamp
    $pollingWaitSeconds = 0
    if ($State.localizationMode -eq 'none') {
        $external = [ordered]@{ status = 'not-applicable'; reason = 'localization mode none'; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
        $snapshot = [ordered]@{ headRefOid = $State.headOid; reviews = @(); reviewRequests = @(); comments = @() }
    }
    elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $external = [ordered]@{ status = 'unavailable'; reason = 'gh is unavailable'; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
        $snapshot = [ordered]@{}
    }
    else {
        $view = Invoke-Gh -Arguments @('pr', 'view', [string]$State.prNumber, '--json', 'headRefOid,reviews,reviewRequests,comments') -AllowFailure
        if ($view.exitCode -ne 0) {
            $external = [ordered]@{ status = 'unavailable'; reason = "$($view.warning) $($view.output)".Trim(); headOid = $State.headOid; verifiedAt = $snapshotAt; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
            $snapshot = [ordered]@{}
        }
        else {
            $snapshot = $view.output | ConvertFrom-Json -AsHashtable
            if ($snapshot.headRefOid -ne $State.headOid) { throw 'PR head does not equal immutable F during review snapshot.' }
            $matching = @($snapshot.reviews | Where-Object { $_.author.login -match 'copilot-pull-request-reviewer' -and $_.commit.oid -eq $State.headOid } | Sort-Object submittedAt -Descending)
            $requested = @($snapshot.reviewRequests | Where-Object { $_.login -match 'copilot-pull-request-reviewer' })
            $external = if ($matching.Count -ge 1) {
                [ordered]@{ status = 'completed'; headOid = $State.headOid; reviewId = $matching[0].id; reviewerLogin = $matching[0].author.login; submittedAt = $matching[0].submittedAt; reviewCommitOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
            }
            else {
                $requestEvidence = $null
                if ($requested.Count -eq 0 -and $State.externalReview.status -eq 'not-requested') {
                    $repositoryName = ((Invoke-Gh -Arguments @('repo', 'view', '--json', 'nameWithOwner')).output | ConvertFrom-Json -AsHashtable).nameWithOwner
                    $request = Invoke-Gh -Arguments @('api', '--method', 'POST', "repos/$repositoryName/pulls/$($State.prNumber)/requested_reviewers", '-f', 'reviewers[]=copilot-pull-request-reviewer[bot]') -AllowFailure
                    $requestEvidence = [ordered]@{ exitCode = $request.exitCode; requestedAt = Get-UtcTimestamp; warning = $request.warning }
                }
                [ordered]@{ status = 'requested-pending'; reason = 'No completed Copilot review existed in the one bounded snapshot; no polling was scheduled.'; requestEvidence = $requestEvidence; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
            }
        }
    }
    if ($pollingWaitSeconds -ne 0) { throw 'External Review polling wait must remain zero.' }
    $artifactPath = Join-Path $State.artifactsRoot 'review-snapshot.json'
    Write-AtomicJson -Path $artifactPath -Value ([ordered]@{ snapshot = $snapshot; externalReview = $external })
    $State.externalReview = $external
    $State.reviewedOid = $State.headOid
    Save-State -State $State
    $updatedBody = Get-PrBody -State $State
    $null = Invoke-Gh -Arguments @('pr', 'edit', [string]$State.prNumber, '--body', $updatedBody)
    $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
    $completion = & $validator -StatePath $State.statePath -ReviewCompletion -PassThru
    if ($completion.result -ne 'passed') { throw 'Independent Review completion validation rejected the current F.' }
    $State.status = 'awaiting-user-merge'
    $ownerPath = Join-Path $State.modLockPath 'owner.json'
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
    $owner.leaseMode = 'reserved'; $owner.workerId = $null; $owner.heartbeat = Get-UtcTimestamp
    Write-AtomicJson -Path $ownerPath -Value $owner
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $completion.sha256 -Data ([ordered]@{ externalReview = $external; localReview = $State.localReview; completionValidation = $completion })
}

function Resolve-InitialState {
    if ([string]::IsNullOrWhiteSpace($StatePath)) { throw "$Command requires -StatePath." }
    Read-State -Path ([IO.Path]::GetFullPath($StatePath))
}

function Invoke-StageCommand {
    param([string] $StageName, [Collections.IDictionary] $State)
    switch ($StageName) {
        'verify-source' { Invoke-VerifySource -State $State }
        'extract' { Invoke-Extract -State $State }
        'install' { Invoke-Install -State $State }
        'localization' { Invoke-Localization -State $State }
        'build-commits' { Invoke-BuildCommits -State $State }
        'validate' { Invoke-Validate -State $State }
        'publish' { Invoke-Publish -State $State }
        'review-snapshot' { Invoke-ReviewSnapshot -State $State }
        default { throw "Unsupported stage: $StageName" }
    }
}

$writerLease = $null
try {
    $result = if ($Command -eq 'claim') {
        if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            $state = Read-State -Path $StatePath
            $writerLease = Enter-RunWriterLock -State $state
        }
        Invoke-Claim
    }
    elseif ($Command -eq 'run') {
        $state = if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            Read-State -Path $StatePath
        }
        else {
            $claimResult = Invoke-Claim
            Read-State -Path $claimResult.statePath
        }
        $writerLease = Enter-RunWriterLock -State $state
        $state = Read-State -Path $state.statePath
        $last = $null
        foreach ($stageName in @('verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot')) {
            if ($stageName -eq 'review-snapshot' -and [string]::IsNullOrWhiteSpace($LocalReviewPath)) {
                $last = [ordered]@{
                    result = 'waiting-input'; runId = $state.runId; stage = 'local-review'; status = $state.status; statePath = $state.statePath
                    data = [ordered]@{ required = 'Expand and read the packaged Review Baseline, review the current F, then resume run with -LocalReviewPath.'; headOid = $state.evidenceChain.fOid; candidateGateSha256 = $state.candidateGate.validationReportSha256 }
                }
                break
            }
            $last = Invoke-StageCommand -StageName $stageName -State $state
            $state = Read-State -Path $state.statePath
            if ($state.status -eq $Until) { break }
        }
        $last
    }
    else {
        $state = Resolve-InitialState
        $writerLease = Enter-RunWriterLock -State $state
        $state = Read-State -Path $state.statePath
        Invoke-StageCommand -StageName $Command -State $state
    }

    if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 40 -Compress }
}
catch {
    $errorResult = [ordered]@{
        result = 'failed'
        stage = $Command
        statePath = $StatePath
        error = $_.Exception.Message
        at = Get-UtcTimestamp
    }
    if ($writerLease -and $StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        try {
            $failedState = Read-State -Path $StatePath
            $failedState.lastError = $errorResult
            $failedState.status = if ($_.Exception.Message -match 'identity|security|archive|path|user') { 'waiting-user' } else { 'failed' }
            Save-State -State $failedState
        }
        catch { }
    }
    if ($PassThru) { throw }
    $errorResult | ConvertTo-Json -Depth 20 -Compress
    exit 1
}
finally {
    if ($writerLease) { Exit-RunWriterLock -Lease $writerLease }
}
