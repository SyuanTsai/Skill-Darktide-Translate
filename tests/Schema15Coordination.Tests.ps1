# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Schema 15 multi-process coordination contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $layout = Get-TestRepositoryLayout -RepositoryRoot $repoRoot
        $skillRoot = $layout.SkillRoot
        $scriptRoot = Join-Path $skillRoot 'scripts'
        $runnerPath = Join-Path $scriptRoot 'mod-update.ps1'
        $coordinationModule = Join-Path $scriptRoot 'SharedCoordinationLock.psm1'
        $script:skillSourcePinPath = New-TestSkillSourcePin -SkillRoot $skillRoot `
            -OutputPath (Join-Path $TestDrive 'coordination-skill-source-pin.json')
    }

    # Scenario: PowerShell predates ConvertFrom-Json -DateKind but reads an immutable UTC source tuple.
    # Purpose: Preserve timestamp text exactly instead of converting it to the machine's local time zone.
    It 'UnitT10_PreservesJsonTimestampStringsWithoutNativeDateKind' {
        Import-Module -Name $coordinationModule -Force
        InModuleScope SharedCoordinationLock {
            Mock Get-Command { [pscustomobject]@{ Parameters = @{} } } `
                -ParameterFilter { $Name -ceq 'Microsoft.PowerShell.Utility\ConvertFrom-Json' }
            $expected = '2026-01-02T03:04:05.0000000+00:00'
            $parsed = '{"at":"2026-01-02T03:04:05.0000000+00:00","items":[{"value":1}],"empty":[]}' |
                ConvertFrom-Json -AsHashtable

            $parsed.at.GetType() | Should -Be ([string])
            $parsed.at | Should -BeExactly $expected
            @($parsed.items).Count | Should -Be 1
            $parsed.items[0].value | Should -Be 1
            @($parsed.empty).Count | Should -Be 0
        }
    }

    # Scenario: Lease publication reports either a local no-replace/CAS race or an unrelated storage failure.
    # Purpose: Retry only genuine publication contention while surfacing every other failure immediately with its cause intact.
    It 'UnitT20_WaitsOnlyForLocalPublicationContention_<Case>' -ForEach @(
        @{ Case = 'NoReplaceTargetExists'; Competition = $true }
        @{ Case = 'CasExpectedStateMismatch'; Competition = $true }
        @{ Case = 'IoFailure'; Competition = $false }
    ) {
        Import-Module -Name $coordinationModule -Force
        $coordinationModuleObject = Get-Module -Name SharedCoordinationLock | Select-Object -First 1
        $coordinationModuleObject | Should -Not -BeNullOrEmpty
        InModuleScope $coordinationModuleObject -Parameters @{ Case = $Case; Competition = $Competition } {
            Mock Enter-CoordinationOwnerGuard {
                $guard = [pscustomobject]@{}
                $guard | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
                $guard
            }
            Mock Get-CoordinationLeaseSnapshot {
                [ordered]@{ exists = $false; bytes = $null; sha256 = $null; length = $null; identity = $null }
            }
            Mock Publish-CoordinationLeaseSnapshot {
                switch ($Case) {
                    { $_ -in @('NoReplaceTargetExists', 'CasExpectedStateMismatch') } {
                        $failure = [IO.IOException]::new('injected local publication contention')
                        $failure.Data['PortablePublicationKind'] = if ($Case -ceq 'NoReplaceTargetExists') {
                            'no-replace-target-exists'
                        }
                        else { 'cas-expected-state-mismatch' }
                        throw $failure
                    }
                    default { throw [IO.IOException]::new('injected coordination storage failure') }
                }
            }

            $repository = Join-Path $TestDrive ("publication-contention-$Case")
            [void][IO.Directory]::CreateDirectory($repository)
            $script:coordinationWaitHeartbeatCount = 0
            $heartbeat = {
                $script:coordinationWaitHeartbeatCount++
                if ($script:coordinationWaitHeartbeatCount -ge 2) {
                    throw [InvalidOperationException]::new('observed coordination retry wait')
                }
            }

            if ($Competition) {
                { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                        -RunId "contention-$Case" -WaitHeartbeatAction $heartbeat -TimeoutSeconds 10 } |
                    Should -Throw '*observed coordination retry wait*'
                $script:coordinationWaitHeartbeatCount | Should -Be 2
            }
            else {
                $failure = { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                        -RunId "contention-$Case" -WaitHeartbeatAction $heartbeat -TimeoutSeconds 10 } |
                    Should -Throw '*injected coordination storage failure*' -PassThru
                $script:coordinationWaitHeartbeatCount | Should -Be 1
                $failure.Exception | Should -BeOfType ([IO.IOException])
                $failure.Exception.InnerException.Message | Should -BeExactly 'injected coordination storage failure'
            }
            Should -Invoke Publish-CoordinationLeaseSnapshot -Times 1 -Exactly
            Remove-Variable -Name coordinationWaitHeartbeatCount -Scope Script -ErrorAction SilentlyContinue
        }
    }

    # Scenario: Two mods compete with a duplicate generation in a long run-owned Windows fixture path.
    # Purpose: Preserve cross-process serialization and competing-generation rejection after verified Git fixture setup.
    It 'InterT180_SerializesTwoModsAndRejectsACompetingGenerationAcrossProcesses' -Tag 'MultiProcess' {
        $repository = Join-Path $TestDrive 'multi-process-repository'
        $modsRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods'
        $queueRoot = Join-Path $repository 'AI Auto Update'
        New-Item -ItemType Directory -Path (Join-Path $modsRoot 'ModA'), (Join-Path $modsRoot 'ModB'), $queueRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $modsRoot 'ModA/a.txt'), 'old-a', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $modsRoot 'ModB/b.txt'), 'old-b', [Text.UTF8Encoding]::new($false))
        & git -C $repository init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the coordination Git fixture.' }
        # The protected runner's run-owned TEMP can put fixture Git objects beyond MAX_PATH.
        & git -C $repository config core.longpaths true
        if ($LASTEXITCODE -ne 0) { throw 'Failed to enable long paths for the coordination Git fixture.' }
        & git -C $repository config user.name 'Coordination Test'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to set the coordination Git fixture name.' }
        & git -C $repository config user.email 'coordination@example.invalid'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to set the coordination Git fixture email.' }
        $addOutput = @(& git -C $repository add . 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ('Coordination fixture Git add failed: ' + ($addOutput -join ' ')) }
        & git -C $repository commit --quiet -m 'coordination fixture base'
        if ($LASTEXITCODE -ne 0) { throw 'Failed to commit the coordination Git fixture.' }

        function New-TestArchive {
            param([string] $Path, [string] $ModName, [string] $Content)
            $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entry = $archive.CreateEntry("$ModName/content.txt")
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write($Content) } finally { $writer.Dispose() }
            }
            finally { $archive.Dispose(); $stream.Dispose() }
        }

        function New-TestRequest {
            param([string] $Path, [int] $ModId, [int] $FileId, [string] $FileName)
            [ordered]@{
                schemaVersion = 2
                gameDomain = 'warhammer40kdarktide'
                modId = $ModId
                mainFileId = $FileId
                version = '2.0.0'
                fileName = $FileName
                pageUrl = "https://www.nexusmods.com/warhammer40kdarktide/mods/$ModId"
                pageVersion = '2.0.0'
                pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'
                mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
            } | ConvertTo-Json | Set-Content -LiteralPath $Path -NoNewline
        }

        function Start-ClaimWorker {
            param([string] $ModName, [string] $ArchivePath, [string] $RequestPath, [string] $RunId)
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Process -Id $PID).Path
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerPath, 'claim',
                '-RepositoryRoot', $repository, '-ArchivePath', $ArchivePath, '-ModDirectory', $ModName,
                '-RunId', $RunId, '-SourceRequestPath', $RequestPath,
                '-SkillSourcePinPath', $script:skillSourcePinPath, '-BaseRef', 'HEAD',
                '-WorktreeParent', $TestDrive
            )) { $start.ArgumentList.Add($argument) }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $start
            if (-not $process.Start()) { throw "Unable to start claim worker for $ModName." }
            [ordered]@{
                mod = $ModName
                runId = $RunId
                process = $process
                stdout = $process.StandardOutput.ReadToEndAsync()
                stderr = $process.StandardError.ReadToEndAsync()
            }
        }

        $archiveA = Join-Path $queueRoot 'ModA.zip'
        $archiveB = Join-Path $queueRoot 'ModB.zip'
        New-TestArchive -Path $archiveA -ModName 'ModA' -Content 'new-a'
        New-TestArchive -Path $archiveB -ModName 'ModB' -Content 'new-b'
        $requestA = Join-Path $TestDrive 'ModA-source-request.json'
        $requestB = Join-Path $TestDrive 'ModB-source-request.json'
        New-TestRequest -Path $requestA -ModId 181 -FileId 1181 -FileName 'ModA.zip'
        New-TestRequest -Path $requestB -ModId 182 -FileId 1182 -FileName 'ModB.zip'

        $workers = @(
            Start-ClaimWorker -ModName 'ModA' -ArchivePath $archiveA -RequestPath $requestA -RunId '18181818-1111-4111-8111-111111111111'
            Start-ClaimWorker -ModName 'ModB' -ArchivePath $archiveB -RequestPath $requestB -RunId '18181818-2222-4222-8222-222222222222'
            Start-ClaimWorker -ModName 'ModA' -ArchivePath $archiveA -RequestPath $requestA -RunId '18181818-3333-4333-8333-333333333333'
        )
        try {
            $deadline = [DateTimeOffset]::UtcNow.AddMinutes(3)
            while (@($workers | Where-Object { -not $_.process.HasExited }).Count -gt 0) {
                if ([DateTimeOffset]::UtcNow -gt $deadline) {
                    foreach ($worker in $workers | Where-Object { -not $_.process.HasExited }) { $worker.process.Kill($true) }
                    throw 'Timed out waiting for multi-process claim workers.'
                }
                Start-Sleep -Milliseconds 100
            }
            foreach ($worker in $workers) {
                $worker.process.WaitForExit()
                $worker['stdoutText'] = $worker.stdout.Result.Trim()
                $worker['stderrText'] = $worker.stderr.Result.Trim()
            }

            $successful = @($workers | Where-Object { $_.process.ExitCode -eq 0 })
            $failed = @($workers | Where-Object { $_.process.ExitCode -ne 0 })
            $workerDiagnostics = ($workers | ForEach-Object {
                "mod=$($_.mod); exit=$($_.process.ExitCode); stderr=$($_.stderrText); stdout=$($_.stdoutText)"
            }) -join "`n"
            $successful.Count | Should -Be 2 -Because $workerDiagnostics
            $failed.Count | Should -Be 1
            @($successful.mod | Sort-Object) | Should -Be @('ModA', 'ModB')
            $failed[0].mod | Should -Be 'ModA'

            $successfulResults = @($successful | ForEach-Object { $_.stdoutText | ConvertFrom-TestJson -AsHashtable })
            foreach ($result in $successfulResults) { [string]$result.result | Should -Be 'passed' }
            $states = @($successfulResults | ForEach-Object { Get-Content -LiteralPath ([string]$_.statePath) -Raw | ConvertFrom-TestJson -AsHashtable })
            @($states.repoModDirectory | Sort-Object) | Should -Be @('ModA', 'ModB')
            @($states.runId | Sort-Object -Unique).Count | Should -Be 2
            @($states.claimPath | Sort-Object -Unique).Count | Should -Be 2
            @($states.worktreePath | Sort-Object -Unique).Count | Should -Be 2
            @($states.archive.path | Sort-Object -Unique).Count | Should -Be 2
            foreach ($state in $states) {
                [IO.Path]::GetFileName([string]$state.archive.path) | Should -Be "$($state.repoModDirectory).zip"
                Test-Path -LiteralPath ([string]$state.archive.path) -PathType Leaf | Should -BeTrue
                [string]$state.prNumber | Should -BeNullOrEmpty
                [bool]$state.published | Should -BeFalse
                $owner = Get-Content -LiteralPath ([string]$state.modLockPath) -Raw | ConvertFrom-TestJson -AsHashtable
                [string]$owner.state | Should -Be 'held'
                [string]$owner.leaseMode | Should -Be 'reserved'
                [string]$owner.workerToken | Should -BeNullOrEmpty
                $owner.workerId | Should -BeNullOrEmpty
                $owner.workerProcessStartTicks | Should -BeNullOrEmpty
                @($state.coordinationReceipts.resourceKey) | Should -Contain 'source-acquisition'
                @($state.coordinationReceipts.resourceKey) | Should -Contain 'git-coordination'
            }
            @(Get-ChildItem -LiteralPath (Join-Path $queueRoot '.claims') -Directory).Count | Should -Be 2
            @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'In Progress/.locks/mod') -File -Filter '*.lock').Count | Should -Be 2

            $receipts = @($states.coordinationReceipts | ForEach-Object {
                Get-Content -LiteralPath ([string]$_.path) -Raw | ConvertFrom-TestJson -AsHashtable
            })
            foreach ($resourceKey in @('source-acquisition', 'git-coordination')) {
                $timeline = @($receipts | Where-Object { $_.resourceKey -ceq $resourceKey } | Sort-Object {
                    [DateTimeOffset]::ParseExact([string]$_.acquiredAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                })
                for ($index = 1; $index -lt $timeline.Count; $index++) {
                    $acquiredAt = [DateTimeOffset]::ParseExact([string]$timeline[$index].acquiredAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    $priorCompletedAt = [DateTimeOffset]::ParseExact([string]$timeline[$index - 1].completedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    $acquiredAt | Should -BeGreaterOrEqual $priorCompletedAt
                }
            }
        }
        finally {
            foreach ($worker in $workers) {
                if (-not $worker.process.HasExited) { $worker.process.Kill($true) }
                $worker.process.Dispose()
            }
        }
    }

    # Scenario: A crashed owner expires and a new owner replaces the same long-lived file by CAS.
    # Purpose: Recover stale ownership without deleting the lease name and keep old tokens unable to release the successor.
    It 'InterT181_ReclaimsAnExpiredSingleFileLeaseAndRejectsTheOldToken' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'stale-shared-lock-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $receiptRoot = Join-Path $repository 'AI Auto Update/In Progress/stale-test-artifacts'
        $crashWorkerPath = Join-Path $TestDrive 'crash-coordination-worker.ps1'
        $oldLeasePath = Join-Path $TestDrive 'crashed-lease.json'
        @'
param([string] $ModulePath, [string] $Repository, [string] $ReceiptRoot, [string] $LeasePath)
Import-Module -Name $ModulePath -Force
$lease = Enter-SharedCoordinationLease -RepositoryRoot $Repository -ResourceKey 'source-acquisition' `
    -RunId '18181818-4444-4444-8444-444444444444' -ReceiptRoot $ReceiptRoot
$lease | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $LeasePath -NoNewline
[Environment]::Exit(91)
'@ | Set-Content -LiteralPath $crashWorkerPath -NoNewline
        $crashStart = [Diagnostics.ProcessStartInfo]::new()
        $crashStart.FileName = (Get-Process -Id $PID).Path
        $crashStart.UseShellExecute = $false
        $crashStart.RedirectStandardOutput = $true
        $crashStart.RedirectStandardError = $true
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $crashWorkerPath,
            '-ModulePath', $coordinationModule, '-Repository', $repository,
            '-ReceiptRoot', $receiptRoot, '-LeasePath', $oldLeasePath
        )) { $crashStart.ArgumentList.Add($argument) }
        $crashProcess = [Diagnostics.Process]::new()
        $crashProcess.StartInfo = $crashStart
        $crashProcess.Start() | Should -BeTrue
        $crashOutput = $crashProcess.StandardOutput.ReadToEndAsync()
        $crashError = $crashProcess.StandardError.ReadToEndAsync()
        $crashProcess.WaitForExit(30000) | Should -BeTrue
        $crashProcess.ExitCode | Should -Be 91 -Because ($crashError.Result + $crashOutput.Result)
        $crashProcess.Dispose()
        $oldLease = Get-Content -LiteralPath $oldLeasePath -Raw | ConvertFrom-TestJson -AsHashtable
        $ownerPath = [string]$oldLease.path
        $oldOwner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-TestJson -AsHashtable
        [string]$oldOwner.platform | Should -BeExactly ([string]$oldLease.platform)
        [string]$oldOwner.lockPrimitive | Should -BeExactly ([string]$oldLease.lockPrimitive)
        [string]$oldOwner.state | Should -Be 'held'
        $oldOwner.owner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
        $oldOwner.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
        $oldOwner | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerPath -NoNewline
        [byte[]]$staleOwnerBytes = [IO.File]::ReadAllBytes($ownerPath)

        $newLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' `
            -RunId '18181818-5555-4555-8555-555555555555' -ReceiptRoot $receiptRoot
        try {
            { Exit-SharedCoordinationLease -Lease $oldLease } | Should -Throw '*ownership changed*'
            Test-Path -LiteralPath ([string]$newLease.path) -PathType Leaf | Should -BeTrue
            $newOwner = Get-Content -LiteralPath ([string]$newLease.path) -Raw | ConvertFrom-TestJson -AsHashtable
            [string]$newOwner.owner.token | Should -Be ([string]$newLease.token)
            [string]$newOwner.platform | Should -BeExactly ([string]$newLease.platform)
            [string]$newOwner.lockPrimitive | Should -BeExactly ([string]$newLease.lockPrimitive)
            $beforeHeartbeat = [DateTimeOffset]$newOwner.owner.heartbeat
            Start-Sleep -Milliseconds 20
            Update-SharedCoordinationLease -Lease $newLease -Force
            $refreshedOwner = Get-Content -LiteralPath ([string]$newLease.path) -Raw | ConvertFrom-TestJson -AsHashtable
            [DateTimeOffset]$refreshedOwner.owner.heartbeat | Should -BeGreaterThan $beforeHeartbeat
            [DateTimeOffset]$refreshedOwner.expiresAt | Should -BeGreaterThan ([DateTimeOffset]$refreshedOwner.owner.heartbeat)
        }
        finally {
            $receipt = Exit-SharedCoordinationLease -Lease $newLease
        }
        Test-Path -LiteralPath ([string]$newLease.path) -PathType Leaf | Should -BeTrue
        $releasedOwner = Get-Content -LiteralPath ([string]$newLease.path) -Raw | ConvertFrom-TestJson -AsHashtable
        [string]$releasedOwner.state | Should -Be 'released'
        $receiptRecord = Get-Content -LiteralPath ([string]$receipt.path) -Raw | ConvertFrom-TestJson -AsHashtable
        [string]$newLease.staleEvidencePath | Should -Not -BeNullOrEmpty
        [string]$receiptRecord.staleEvidencePath | Should -Be ([string]$newLease.staleEvidencePath)
        [string]$newLease.staleEvidencePath | Should -Match '[\\/]\.source-acquisition\.lock\.stale-[0-9a-f]{64}\.json$'
        Test-Path -LiteralPath ([string]$newLease.staleEvidencePath) -PathType Leaf | Should -BeTrue
        [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$newLease.staleEvidencePath)) |
            Should -BeExactly ([Convert]::ToHexString($staleOwnerBytes))
        $staleOwner = Get-Content -LiteralPath ([string]$newLease.staleEvidencePath) -Raw |
            ConvertFrom-TestJson -AsHashtable
        [string]$staleOwner.owner.token | Should -BeExactly ([string]$oldLease.token)
    }

    It 'InterT182_HeartbeatsWhileWaitingAndRejectsMalformedStaleProcessIdentity' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-wait-contract-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
            -RunId '18218218-2182-4182-8182-182182182182'
        try {
            $counter = [Runtime.CompilerServices.StrongBox[int]]::new(0)
            $waitHeartbeat = { $counter.Value++ }.GetNewClosure()
            { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                -RunId '18218218-3182-4182-8182-182182182182' -TimeoutSeconds 1 `
                -WaitHeartbeatAction $waitHeartbeat } | Should -Throw '*Timed out*'
            $counter.Value | Should -BeGreaterThan 1

            $ownerPath = [string]$lease.path
            $validOwnerJson = Get-Content -LiteralPath $ownerPath -Raw
            try {
                $malformedOwner = $validOwnerJson | ConvertFrom-TestJson -AsHashtable
                $malformedOwner.owner.processStartTicks = 'not-a-number'
                $malformedOwner.owner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
                $malformedOwner.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
                $malformedOwner | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerPath -NoNewline
                { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                    -RunId '18218218-4182-4182-8182-182182182182' -TimeoutSeconds 1 } |
                    Should -Throw '*owner contract is invalid*'
                Test-Path -LiteralPath ([string]$lease.path) -PathType Leaf | Should -BeTrue
            }
            finally {
                [IO.File]::WriteAllText($ownerPath, $validOwnerJson, [Text.UTF8Encoding]::new($false))
            }
        }
        finally {
            $null = Exit-SharedCoordinationLease -Lease $lease
        }
    }

    # Scenario: A worker successfully acquires a shared lock after observing another live owner.
    # Purpose: Prove the production lease reports real contention time instead of relying only on a stubbed timing value.
    It 'InterT183_ReportsElapsedCoordinationWaitAfterContention' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-wait-timing-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $heartbeatPath = Join-Path $TestDrive 'coordination-wait-heartbeat.txt'
        $resultPath = Join-Path $TestDrive 'coordination-wait-result.json'
        $workerPath = Join-Path $TestDrive 'coordination-wait-worker.ps1'
        @'
param(
    [string] $ModulePath,
    [string] $Repository,
    [string] $HeartbeatPath,
    [string] $ResultPath
)
Import-Module -Name $ModulePath -Force
$callbackCount = [Runtime.CompilerServices.StrongBox[int]]::new(0)
$waitHeartbeat = {
    $callbackCount.Value++
    [IO.File]::WriteAllText($HeartbeatPath, ([string]$callbackCount.Value), [Text.UTF8Encoding]::new($false))
}.GetNewClosure()
$clock = [Diagnostics.Stopwatch]::StartNew()
$lease = Enter-SharedCoordinationLease -RepositoryRoot $Repository -ResourceKey 'git-coordination' `
    -RunId '18318318-3183-4183-8183-183183183183' -TimeoutSeconds 10 `
    -WaitHeartbeatAction $waitHeartbeat
$clock.Stop()
try {
    $observation = [ordered]@{
        observedMilliseconds = [int64]$clock.ElapsedMilliseconds
        waitingMilliseconds = [int64]$lease.waitingMilliseconds
    }
    [IO.File]::WriteAllText($ResultPath, ($observation | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}
finally {
    $null = Exit-SharedCoordinationLease -Lease $lease
}
'@ | Set-Content -LiteralPath $workerPath -NoNewline

        $firstLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
            -RunId '18318318-2183-4183-8183-183183183183'
        $worker = $null
        try {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Process -Id $PID).Path
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $workerPath,
                '-ModulePath', $coordinationModule, '-Repository', $repository,
                '-HeartbeatPath', $heartbeatPath, '-ResultPath', $resultPath
            )) { $start.ArgumentList.Add($argument) }
            $worker = [Diagnostics.Process]::new()
            $worker.StartInfo = $start
            $worker.Start() | Should -BeTrue
            $stdout = $worker.StandardOutput.ReadToEndAsync()
            $stderr = $worker.StandardError.ReadToEndAsync()

            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            $observedHeartbeatCount = 0
            while ($observedHeartbeatCount -lt 2) {
                if ($worker.HasExited) { break }
                if ([DateTimeOffset]::UtcNow -gt $deadline) { break }
                if (Test-Path -LiteralPath $heartbeatPath -PathType Leaf) {
                    try {
                        $heartbeatText = [IO.File]::ReadAllText($heartbeatPath)
                        $parsedCount = 0
                        if ([int]::TryParse($heartbeatText, [ref]$parsedCount)) { $observedHeartbeatCount = $parsedCount }
                    }
                    catch [IO.IOException] { }
                }
                Start-Sleep -Milliseconds 20
            }
            $observedHeartbeatCount | Should -BeGreaterOrEqual 2 -Because 'the worker must observe a live owner before release'
            Start-Sleep -Milliseconds 300
            $null = Exit-SharedCoordinationLease -Lease $firstLease
            $firstLease = $null

            $worker.WaitForExit(30000) | Should -BeTrue
            $worker.ExitCode | Should -Be 0 -Because ($stderr.Result + $stdout.Result)
            Test-Path -LiteralPath $resultPath -PathType Leaf | Should -BeTrue
            $observation = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-TestJson -AsHashtable
            [int64]$observation.waitingMilliseconds | Should -BeGreaterThan 0
            [int64]$observation.waitingMilliseconds | Should -BeLessOrEqual ([int64]$observation.observedMilliseconds)
            ([int64]$observation.observedMilliseconds - [int64]$observation.waitingMilliseconds) |
                Should -BeLessThan 5000
        }
        finally {
            if ($firstLease) { $null = Exit-SharedCoordinationLease -Lease $firstLease }
            if ($worker) {
                if (-not $worker.HasExited) { $worker.Kill($true) }
                $worker.Dispose()
            }
        }
    }

    # Scenario: A lease is released and reacquired from its persistent file, then a legacy directory is placed at that name.
    # Purpose: Prove released-file reuse and fail-closed migration guidance without automatic legacy conversion.
    It 'InterT370_ReacquiresAReleasedFileAndRejectsALegacyDirectoryWithMigrationSteps' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'lock-evidence-repository'
        $receiptRoot = Join-Path $repository 'receipts'
        New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
        $expectedPlatform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
        $expectedPrimitive = 'dotnet-fileshare-none'

        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'evidence-run' -ReceiptRoot $receiptRoot -TimeoutSeconds 10
        $lease.platform | Should -BeExactly $expectedPlatform
        $lease.lockPrimitive | Should -BeExactly $expectedPrimitive
        $receipt = Exit-SharedCoordinationLease -Lease $lease
        $receiptValue = Get-Content -LiteralPath $receipt.path -Raw | ConvertFrom-TestJson -AsHashtable
        $receiptValue.platform | Should -BeExactly $expectedPlatform
        $receiptValue.lockPrimitive | Should -BeExactly $expectedPrimitive
        $receiptValue.disposition | Should -BeExactly 'released'

        Test-Path -LiteralPath $lease.path -PathType Leaf | Should -BeTrue
        $releasedValue = Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable
        $releasedValue.state | Should -BeExactly 'released'
        $secondLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'second-run' -TimeoutSeconds 10
        try { [string]$secondLease.token | Should -Not -BeExactly ([string]$lease.token) }
        finally { $null = Exit-SharedCoordinationLease -Lease $secondLease }

        $lockRoot = Join-Path $repository 'AI Auto Update/In Progress/.locks'
        $guardPath = Join-Path $lockRoot 'git-coordination.owner-update.guard'
        Test-Path -LiteralPath $guardPath -PathType Leaf | Should -BeTrue -Because 'the native lock keeps a fixed guard file'
        $emptyLease = Join-Path $lockRoot 'git-coordination.lock'
        [IO.File]::Delete($emptyLease)
        New-Item -ItemType Directory -Path $emptyLease | Out-Null
        { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'legacy-run' -TimeoutSeconds 2 } |
            Should -Throw '*Legacy coordination lease directory format*move this directory*outside .locks*Automatic deletion or migration is forbidden*'
        Test-Path -LiteralPath $emptyLease -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $emptyLease -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $lockRoot -Force -Directory | Where-Object { $_.Name -like '.pending-*' }).Count | Should -Be 0

        $coordination = Get-Content -LiteralPath $coordinationModule -Raw
        $coordination | Should -Match 'Publish-PortableLeaseFile'
        $coordination | Should -Match "state = 'held'"
        $coordination | Should -Match "state = 'released'"
        $coordination | Should -Not -Match '\[IO\.Directory\]::Move'
        $coordination | Should -Not -Match '\[IO\.File\]::Delete\(\$ownerPath\)'
        $coordination | Should -Not -Match '\[IO\.Directory\]::Delete\(\[string\]\$Lease\.path\)'
        $coordination | Should -Not -Match 'FileShare\]::None'
    }

    # Scenario: A writer reads one file identity, another CAS replaces it, and the first writer retries with stale evidence.
    # Purpose: Prove replacement requires the exact observed identity/hash/length tuple and rejects a lost race.
    It 'InterT380_RejectsAStaleExpectedIdentityDuringCasReplacement' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-cas-race-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'cas-owner'
        try {
            $coordinationModuleObject = Get-Module -Name SharedCoordinationLock | Select-Object -First 1
            $coordinationModuleObject | Should -Not -BeNullOrEmpty
            InModuleScope $coordinationModuleObject -Parameters @{ Repository = $repository } {
                $lockRoot = Join-Path $Repository 'AI Auto Update/In Progress/.locks'
                $stale = Get-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey 'source-acquisition'
                $replacement = $stale.value
                $replacement.owner.heartbeat = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o')
                $replacement.expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
                $null = Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey 'source-acquisition' -Value $replacement -ExpectedState $stale
                { Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey 'source-acquisition' -Value $replacement -ExpectedState $stale } |
                    Should -Throw
            }
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $lease }
    }

    # Scenario: Acquisition publication completed, but the caller retries before observing the return value.
    # Purpose: The same actor token must recognize its held target state without rewriting it.
    It 'InterT381_RepeatsPublishedAcquisitionForTheSameOwnerTokenWithoutRewrite' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-acquire-retry'
        New-Item -ItemType Directory -Path $repository | Out-Null
        $attemptToken = '1' * 32
        $first = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'same-acquirer' -AttemptToken $attemptToken
        try {
            $before = (Get-FileHash -LiteralPath $first.path -Algorithm SHA256).Hash
            $retry = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'same-acquirer' -AttemptToken $attemptToken
            $retry.token | Should -BeExactly $first.token
            (Get-FileHash -LiteralPath $first.path -Algorithm SHA256).Hash | Should -BeExactly $before
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $first }
    }

    # Scenario: A different actor token attempts acquisition while the target state is already held.
    # Purpose: Wait for normal contention and reject only after the bounded acquisition timeout.
    It 'InterT382_RejectsPublishedAcquisitionByAnotherOwnerToken' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-acquire-other'
        New-Item -ItemType Directory -Path $repository | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'first-acquirer'
        try {
            { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'other-acquirer' -TimeoutSeconds 1 } |
                Should -Throw '*Timed out*'
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $lease }
    }

    # Scenario: A heartbeat target was published before an interrupted caller retried the same transition.
    # Purpose: A non-regressing heartbeat from the same token is idempotent and remains byte-identical.
    It 'InterT383_RepeatsPublishedHeartbeatForTheSameOwnerTokenWithoutRewrite' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-heartbeat-retry'
        New-Item -ItemType Directory -Path $repository | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'heartbeat-owner'
        $coordinationModuleObject = Get-Module -Name SharedCoordinationLock | Select-Object -First 1
        try {
            & $coordinationModuleObject {
                $script:CoordinationFaultInjectionHook = {
                    param($point)
                    if ($point -ceq 'heartbeat-published-before-readback') { throw 'injected heartbeat return interruption' }
                }
            }
            { Update-SharedCoordinationLease -Lease $lease -Force } | Should -Throw '*injected heartbeat return interruption*'
            $before = (Get-FileHash -LiteralPath $lease.path -Algorithm SHA256).Hash
            $lease.Contains('pendingHeartbeat') | Should -BeTrue
            $publishedHeartbeat = [string]$lease.pendingHeartbeat
            & $coordinationModuleObject { $script:CoordinationFaultInjectionHook = $null }
            Update-SharedCoordinationLease -Lease $lease -Force
            (Get-FileHash -LiteralPath $lease.path -Algorithm SHA256).Hash | Should -BeExactly $before
            $lease.Contains('pendingHeartbeat') | Should -BeFalse
            (Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable).owner.heartbeat |
                Should -BeExactly $publishedHeartbeat
        }
        finally {
            & $coordinationModuleObject { $script:CoordinationFaultInjectionHook = $null }
            $null = Exit-SharedCoordinationLease -Lease $lease
        }
    }

    # Scenario: A heartbeat caller presents a token different from the persisted held owner.
    # Purpose: Heartbeat idempotence must never cross actor-token ownership.
    It 'InterT384_RejectsHeartbeatByAnotherOwnerToken' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-heartbeat-other'
        New-Item -ItemType Directory -Path $repository | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'heartbeat-first'
        try {
            $other = [ordered]@{}; foreach ($entry in $lease.GetEnumerator()) { $other[$entry.Key] = $entry.Value }
            $other.token = 'f' * 32
            { Update-SharedCoordinationLease -Lease $other -Force } | Should -Throw '*ownership changed*'
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $lease }
    }

    # Scenario: Release and its immutable terminal receipt were published before the return was observed.
    # Purpose: Retrying the same release succeeds without rewriting the released owner file.
    It 'InterT385_RepeatsPublishedReleaseForTheSameOwnerTokenWithoutRewrite' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-release-retry'
        New-Item -ItemType Directory -Path $repository | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'release-owner'
        $coordinationModuleObject = Get-Module -Name SharedCoordinationLock | Select-Object -First 1
        & $coordinationModuleObject {
            $script:CoordinationFaultInjectionHook = {
                param($point)
                if ($point -ceq 'release-published-before-operational-receipt') { throw 'injected release return interruption' }
            }
        }
        { Exit-SharedCoordinationLease -Lease $lease } | Should -Throw '*injected release return interruption*'
        $before = (Get-FileHash -LiteralPath $lease.path -Algorithm SHA256).Hash
        & $coordinationModuleObject { $script:CoordinationFaultInjectionHook = $null }
        $retry = Exit-SharedCoordinationLease -Lease $lease
        @($retry.Keys) | Should -Be @('path', 'sha256', 'resourceKey')
        $retry.resourceKey | Should -BeExactly 'source-acquisition'
        $retry.path | Should -Match '[\\/]coordination-locks[\\/]source-acquisition-[0-9a-f]{32}\.json$'
        $sameResult = Exit-SharedCoordinationLease -Lease $lease
        ($sameResult | ConvertTo-Json -Compress) | Should -BeExactly ($retry | ConvertTo-Json -Compress)
        (Get-FileHash -LiteralPath $lease.path -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    # Scenario: A different token attempts to claim another owner's released target state.
    # Purpose: Legacy or foreign release state always fails closed.
    It 'InterT386_RejectsPublishedReleaseByAnotherOwnerToken' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'coordination-release-other'
        New-Item -ItemType Directory -Path $repository | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'release-first'
        $null = Exit-SharedCoordinationLease -Lease $lease
        $other = [ordered]@{}; foreach ($entry in $lease.GetEnumerator()) { $other[$entry.Key] = $entry.Value }
        $other.token = 'e' * 32
        { Exit-SharedCoordinationLease -Lease $other } | Should -Throw '*another owner token*'
    }

    # Scenario: A child process remains alive while its persisted expiry is forced into the past.
    # Purpose: Expiry alone must not permit takeover of a verifiably live same-machine owner.
    It 'InterT387_WaitsForALiveExpiredOwnerWithoutChangingLeaseBytes' -Tag 'MultiProcess' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'live-expired-owner'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $leaseRecord = Join-Path $TestDrive 'live-expired-lease.json'
        $stopSignal = Join-Path $TestDrive 'live-expired-stop.signal'
        $workerScript = Join-Path $TestDrive 'live-expired-worker.ps1'
        @'
param($ModulePath,$Repository,$LeaseRecord,$StopSignal)
Import-Module $ModulePath -Force
$lease = Enter-SharedCoordinationLease -RepositoryRoot $Repository -ResourceKey 'git-coordination' -RunId 'live-expired-child'
$lease | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $LeaseRecord -NoNewline
$deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
while (-not [IO.File]::Exists($StopSignal) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
$null = Exit-SharedCoordinationLease -Lease $lease
'@ | Set-Content -LiteralPath $workerScript -NoNewline
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $start.UseShellExecute = $false
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$workerScript,
            '-ModulePath',$coordinationModule,'-Repository',$repository,'-LeaseRecord',$leaseRecord,'-StopSignal',$stopSignal)) {
            $start.ArgumentList.Add($argument)
        }
        $child = [Diagnostics.Process]::Start($start)
        try {
            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not [IO.File]::Exists($leaseRecord) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
            [IO.File]::Exists($leaseRecord) | Should -BeTrue
            $lease = Get-Content -LiteralPath $leaseRecord -Raw | ConvertFrom-TestJson -AsHashtable
            $owner = Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable
            $owner.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
            $owner.owner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
            [IO.File]::WriteAllText([string]$lease.path, ($owner | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
            [byte[]]$expiredBytes = [IO.File]::ReadAllBytes([string]$lease.path)
            { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                    -RunId 'live-expired-contender' -TimeoutSeconds 1 } | Should -Throw '*Timed out*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$lease.path)) |
                Should -BeExactly ([Convert]::ToHexString($expiredBytes))
            (Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable).owner.token |
                Should -BeExactly ([string]$lease.token)
        }
        finally {
            [IO.File]::WriteAllText($stopSignal, '', [Text.UTF8Encoding]::new($false))
            if (-not $child.WaitForExit(10000)) { $child.Kill($true) }
            $child.Dispose()
        }
    }

    # Scenario: Stale-owner CAS publishes, then the acquiring caller is interrupted before displaced evidence verification.
    # Purpose: Same-token retry must recover the exact persisted evidence and reject later tampering.
    It 'InterT388_RecoversPublishedStaleTakeoverEvidenceForTheSameToken' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'stale-takeover-retry'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $dead = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'dead-owner'
        $owner = Get-Content -LiteralPath $dead.path -Raw | ConvertFrom-TestJson -AsHashtable
        $owner.owner.processId = 2147483000
        $owner.owner.processStartTicks = 1
        $owner.owner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
        $owner.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
        [IO.File]::WriteAllText([string]$dead.path, ($owner | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        [byte[]]$displacedBytes = [IO.File]::ReadAllBytes([string]$dead.path)
        $coordinationModuleObject = Get-Module -Name SharedCoordinationLock | Select-Object -First 1
        & $coordinationModuleObject {
            $script:CoordinationFaultInjectionHook = {
                param($point)
                if ($point -ceq 'acquire-published-before-evidence-verification') { throw 'injected stale takeover interruption' }
            }
        }
        $attemptToken = '2' * 32
        { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'retry-owner' -AttemptToken $attemptToken } |
            Should -Throw '*injected stale takeover interruption*'
        & $coordinationModuleObject { $script:CoordinationFaultInjectionHook = $null }
        $retry = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'retry-owner' -AttemptToken $attemptToken
        try {
            $retry.staleEvidencePath | Should -Not -BeNullOrEmpty
            [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$retry.staleEvidencePath)) |
                Should -BeExactly ([Convert]::ToHexString($displacedBytes))
            $retry.waitingMilliseconds | Should -BeGreaterOrEqual 0
            [IO.File]::WriteAllText([string]$retry.staleEvidencePath, 'tampered', [Text.UTF8Encoding]::new($false))
            { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'retry-owner' -AttemptToken $attemptToken } |
                Should -Throw '*differs from the persisted takeover metadata*'
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $retry }
    }

    # Scenario: Two independent acquisitions in one process present the same run ID without sharing an attempt token.
    # Purpose: A fresh acquisition must contend instead of being mistaken for an interrupted retry.
    It 'InterT389_TimesOutAnIndependentSameProcessAcquisitionWithTheSameRunId' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'same-process-independent-acquisition'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'same-run-id'
        try {
            [byte[]]$ownerBytes = [IO.File]::ReadAllBytes([string]$lease.path)
            $ownerToken = (Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable).owner.token
            { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                    -RunId 'same-run-id' -TimeoutSeconds 1 } | Should -Throw '*Timed out*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$lease.path)) |
                Should -BeExactly ([Convert]::ToHexString($ownerBytes))
            (Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable).owner.token |
                Should -BeExactly $ownerToken
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $lease }
    }

    # Scenario: An expired owner is either from another machine or names a PID now used by a different process start.
    # Purpose: Both identities are stale, while malformed owner schemas remain fail closed in InterT182.
    It 'InterT390_ReclaimsAnExpiredOwnerWithStaleIdentity_<Case>' -ForEach @(
        @{ Case = 'ForeignMachine' }
        @{ Case = 'ReusedProcessId' }
    ) {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive "expired-stale-identity-$Case"
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $oldLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId "old-$Case"
        $owner = Get-Content -LiteralPath $oldLease.path -Raw | ConvertFrom-TestJson -AsHashtable
        $owner.owner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
        $owner.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
        if ($Case -ceq 'ForeignMachine') {
            $owner.owner.machineName = "foreign-$([Environment]::MachineName)"
        }
        else {
            $owner.owner.processId = $PID
            $owner.owner.processStartTicks = 1
        }
        [IO.File]::WriteAllText([string]$oldLease.path, ($owner | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $newLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId "new-$Case"
        try {
            $newLease.token | Should -Not -BeExactly $oldLease.token
            $newLease.staleEvidencePath | Should -Not -BeNullOrEmpty
            { Exit-SharedCoordinationLease -Lease $oldLease } | Should -Throw '*ownership changed*'
        }
        finally { $null = Exit-SharedCoordinationLease -Lease $newLease }
    }

    # Scenario: a released shared owner names a missing or byte-tampered immutable terminal receipt.
    # Purpose: A new acquisition must preserve the released owner bytes and fail closed before reuse.
    It 'InterT397_RejectsReleasedOwnerWithInvalidTerminalReceipt_<Case>' -ForEach @(
        @{ Case = 'Missing' }
        @{ Case = 'Tampered' }
    ) {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive "released-receipt-invalid-$Case"
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $lease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId "released-$Case"
        $null = Exit-SharedCoordinationLease -Lease $lease
        [byte[]]$ownerBytes = [IO.File]::ReadAllBytes([string]$lease.path)
        $owner = Get-Content -LiteralPath $lease.path -Raw | ConvertFrom-TestJson -AsHashtable
        $receiptPath = [string]$owner.releaseReceiptPath
        [byte[]]$receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
        try {
            if ($Case -ceq 'Missing') { [IO.File]::Delete($receiptPath) }
            else { [IO.File]::WriteAllBytes($receiptPath, [byte[]]($receiptBytes + 0x20)) }
            { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' `
                    -RunId "replacement-$Case" -TimeoutSeconds 1 } | Should -Throw '*terminal receipt*'
            [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$lease.path)) |
                Should -BeExactly ([Convert]::ToHexString($ownerBytes))
        }
        finally { [IO.File]::WriteAllBytes($receiptPath, $receiptBytes) }
    }

    # Scenario: a released shared owner and immutable receipt are both intact.
    # Purpose: Positive control proves validated released state remains reusable by a distinct acquisition.
    It 'InterT398_ReusesReleasedOwnerAfterTerminalReceiptValidation' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'released-receipt-valid'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $first = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'released-valid-first'
        $null = Exit-SharedCoordinationLease -Lease $first
        $second = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'released-valid-second'
        try { $second.token | Should -Not -BeExactly $first.token }
        finally { $null = Exit-SharedCoordinationLease -Lease $second }
    }
}

Describe 'Incomplete owner publication temporary-file residue guard' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $layout = Get-TestRepositoryLayout -RepositoryRoot $repoRoot
        $skillRoot = $layout.SkillRoot
        $scriptRoot = Join-Path $skillRoot 'scripts'
        $runnerPath = Join-Path $scriptRoot 'mod-update.ps1'
        $coordinationModule = Join-Path $scriptRoot 'SharedCoordinationLock.psm1'
        $pathSafetyModule = Join-Path $scriptRoot 'PathSafety.psm1'

        function New-ModReservationGuardModuleForTest {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) { throw 'The MOD runner does not parse.' }
            $names = @(
                'Assert-NoReparsePath', 'Get-ModReservationOwnerPath', 'Get-ModReservationSnapshot',
                'Read-ModReservationOwner', 'Write-ModReservationOwner', 'Assert-ReleasedModReservationOwnerReusable',
                'Enter-ModReservation'
            )
            $functionSource = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
            }, $true)).Extent.Text -join "`n"
            New-Module -ArgumentList $functionSource, $pathSafetyModule -ScriptBlock {
                param($source, $pathSafetyPath)
                Import-Module -Name $pathSafetyPath -Force
                function Get-CurrentProcessIdentity {
                    [ordered]@{ machineName = 'guard-test'; processId = 42; processStartTicks = 43 }
                }
                function Get-ModReservationActorToken { param($Value) 'a' * 32 }
                function Test-ReservationLeaseMatchesOwner { param($Lease, $Owner) $false }
                function Get-UtcTimestamp { [DateTimeOffset]::UtcNow.ToString('o') }
                . ([scriptblock]::Create($source))
            }
        }
    }

    # Scenario: Shared-owner publication crashed after flushing its recognizable temporary and before the move.
    # Purpose: Block a new shared acquisition without publishing an owner or changing the residue namespace.
    It 'InterT399_BlocksSharedAcquireWhenPublicationTemporaryExistsWithoutOwner' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'shared-publication-residue'
        [void][IO.Directory]::CreateDirectory($repository)
        $first = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' -RunId 'guard-first'
        $lockRoot = Split-Path -Parent ([string]$first.path)
        [byte[]]$ownerBytes = [IO.File]::ReadAllBytes([string]$first.path)
        [IO.File]::Delete([string]$first.path)
        $residuePath = Join-Path $lockRoot ('.source-acquisition.lock.publish-' + ('8' * 32) + '.tmp')
        [IO.File]::WriteAllBytes($residuePath, $ownerBytes)
        [string[]]$namespaceBefore = [IO.Directory]::GetFileSystemEntries($lockRoot)

        { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' `
                -RunId 'guard-second' -TimeoutSeconds 2 } |
            Should -Throw '*BLOCKED*AI Auto Update/In Progress/.locks*Manual recovery for incomplete owner publication*'

        Test-Path -LiteralPath ([string]$first.path) | Should -BeFalse
        [Convert]::ToHexString([IO.File]::ReadAllBytes($residuePath)) |
            Should -BeExactly ([Convert]::ToHexString($ownerBytes))
        [string[]]$namespaceAfter = [IO.Directory]::GetFileSystemEntries($lockRoot)
        ($namespaceAfter -join "`n") | Should -BeExactly ($namespaceBefore -join "`n")
    }

    # Scenario: MOD-owner publication crashed after flushing its recognizable temporary and before the move.
    # Purpose: Block canonical-MOD acquisition without recreating owner or mutating the residue.
    It 'InterT400_BlocksModAcquireWhenPublicationTemporaryExistsWithoutOwner' {
        $module = New-ModReservationGuardModuleForTest
        try {
            $repository = Join-Path $TestDrive 'mod-publication-residue'
            $lockKey = 'd' * 64
            $lockRoot = Join-Path $repository 'AI Auto Update/In Progress/.locks/mod'
            [void][IO.Directory]::CreateDirectory($lockRoot)
            $lockPath = Join-Path $lockRoot "$lockKey.lock"
            $plan = [ordered]@{
                repositoryRoot = $repository
                modLockPath = $lockPath
                lockKey = $lockKey
                modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/GuardedMod'
            }
            & $module {
                param($path, $root)
                Write-ModReservationOwner -ModLockPath $path -Repository $root -Value ([ordered]@{ seed = 'owner' })
            } $lockPath $repository
            [byte[]]$ownerBytes = [IO.File]::ReadAllBytes($lockPath)
            [IO.File]::Delete($lockPath)
            $residuePath = Join-Path $lockRoot (".$lockKey.lock.publish-" + ('6' * 32) + '.tmp')
            [IO.File]::WriteAllBytes($residuePath, $ownerBytes)
            [string[]]$namespaceBefore = [IO.Directory]::GetFileSystemEntries($lockRoot)

            { & $module {
                    param($planValue, $statePath)
                    Enter-ModReservation -Plan $planValue -ActualRunId 'guard-mod-second' -PlannedStatePath $statePath
                } $plan (Join-Path $repository 'AI Auto Update/In Progress/guard-mod-second/state.json') } |
                Should -Throw '*BLOCKED*AI Auto Update/In Progress/.locks/mod*Manual recovery for incomplete owner publication*'

            Test-Path -LiteralPath $lockPath | Should -BeFalse
            [Convert]::ToHexString([IO.File]::ReadAllBytes($residuePath)) |
                Should -BeExactly ([Convert]::ToHexString($ownerBytes))
            [string[]]$namespaceAfter = [IO.Directory]::GetFileSystemEntries($lockRoot)
            ($namespaceAfter -join "`n") | Should -BeExactly ($namespaceBefore -join "`n")
        }
        finally { Remove-Module $module -Force }
    }

    # Scenario: A recognizable publication temporary is a directory or native reparse/symlink entry.
    # Purpose: Treat every matching non-regular entry as residue on every native host.
    It 'InterT401_TreatsNonRegularPublicationTemporaryAsResidue_<Case>' -ForEach @(
        @{ Case = 'Directory' }
        @{ Case = 'ReparseOrSymlink' }
    ) {
        Import-Module -Name $pathSafetyModule -Force
        $lockRoot = Join-Path $TestDrive "non-regular-residue-$Case"
        [void][IO.Directory]::CreateDirectory($lockRoot)
        $entryLeaf = '.owner.lock.publish-' + ('4' * 32) + '.tmp'
        $entry = Join-Path $lockRoot $entryLeaf
        if ($Case -ceq 'Directory') {
            [void][IO.Directory]::CreateDirectory($entry)
        }
        else {
            $target = Join-Path $TestDrive "residue-link-target-$Case"
            [void][IO.Directory]::CreateDirectory($target)
            $null = New-TestReparsePoint -Path $entry -Target $target
        }

        $result = Get-PortableTransactionResidue -LockRoot $lockRoot -OwnerLeaf 'owner.lock'

        $result.hasResidue | Should -BeTrue
        @($result.entries).Count | Should -BeGreaterOrEqual 1
        (@($result.entries) -join "`n") | Should -Match ([regex]::Escape($entryLeaf))
    }

    # Scenario: A stale shared owner is successfully replaced and retained as fixed-name evidence beside the new owner.
    # Purpose: Preserve acquire, heartbeat, and release behavior when residue belongs to a completed stale takeover.
    It 'InterT402_AllowsCompletedStaleTakeoverWithOwnerPresent' {
        Import-Module -Name $coordinationModule -Force
        $repository = Join-Path $TestDrive 'completed-stale-takeover'
        [void][IO.Directory]::CreateDirectory($repository)
        $oldLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'stale-old'
        $owner = Get-Content -LiteralPath $oldLease.path -Raw | ConvertFrom-TestJson -AsHashtable
        $owner.owner.processId = 2147483000
        $owner.owner.processStartTicks = 1
        $owner.owner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
        $owner.expiresAt = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
        [IO.File]::WriteAllText([string]$oldLease.path, ($owner | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))

        $newLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' -RunId 'stale-new'
        $newLease.staleEvidencePath | Should -Match '[\\/]\.git-coordination\.lock\.stale-[0-9a-f]{64}\.json$'
        Test-Path -LiteralPath ([string]$newLease.path) -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath ([string]$newLease.staleEvidencePath) -PathType Leaf | Should -BeTrue
        { Update-SharedCoordinationLease -Lease $newLease -Force } | Should -Not -Throw
        { $script:completedTakeoverReceipt = Exit-SharedCoordinationLease -Lease $newLease } | Should -Not -Throw
        $script:completedTakeoverReceipt | Should -Not -BeNullOrEmpty
    }

    # Scenario: One owner has a publication temporary while holding its owner-update guard, and another owner acquires in the same lock root.
    # Purpose: Wait for the shared namespace guard or ignore another MOD's owner-scoped temporary without weakening target-owner crash blocking.
    It 'InterT403_AllowsAcquisitionDuringAnotherGuardedOwnerReplacement_<Case>' -ForEach @(
        @{ Case = 'Shared' }
        @{ Case = 'Mod' }
    ) {
        $pathSafetyModuleObject = Import-Module -Name $pathSafetyModule -Force -PassThru
        if ($Case -ceq 'Shared') {
            $coordinationModuleObject = Import-Module -Name $coordinationModule -Force -PassThru
            $repository = Join-Path $TestDrive 'shared-in-flight-other-owner'
            [void][IO.Directory]::CreateDirectory($repository)
            $sourceLease = Enter-SharedCoordinationLease -RepositoryRoot $repository `
                -ResourceKey 'source-acquisition' -RunId 'source-in-flight'
            $lockRoot = Split-Path -Parent ([string]$sourceLease.path)
            $guard = & $coordinationModuleObject {
                param($root)
                Enter-CoordinationOwnerGuard -LockRoot $root -ResourceKey 'source-acquisition'
            } $lockRoot
            $temporaryPath = Join-Path $lockRoot ('.source-acquisition.lock.publish-' + ('3' * 32) + '.tmp')
            [IO.File]::WriteAllText($temporaryPath, 'in-flight owner')
            $childPath = Join-Path $TestDrive 'shared-in-flight-contender.ps1'
            $readyPath = Join-Path $TestDrive 'shared-in-flight-contender.ready'
            @'
param([string] $ModulePath, [string] $Repository, [string] $ReadyPath)
$ErrorActionPreference = 'Stop'
Import-Module -Name $ModulePath -Force
[IO.File]::WriteAllText($ReadyPath, 'ready', [Text.UTF8Encoding]::new($false))
$lease = Enter-SharedCoordinationLease -RepositoryRoot $Repository -ResourceKey 'git-coordination' -RunId 'git-during-source-replace' -TimeoutSeconds 10
[Console]::Out.Write(($lease | ConvertTo-Json -Depth 10 -Compress))
'@ | Set-Content -LiteralPath $childPath -Encoding utf8NoBOM
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = (Get-Process -Id $PID).Path
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $childPath,
                    '-ModulePath', $coordinationModule, '-Repository', $repository, '-ReadyPath', $readyPath)) {
                $start.ArgumentList.Add($argument)
            }
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = $start
            $stdout = $null
            $stderr = $null
            $started = $false
            try {
                $process.Start() | Should -BeTrue
                $started = $true
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
                while (-not [IO.File]::Exists($readyPath) -and [DateTimeOffset]::UtcNow -lt $deadline) {
                    Start-Sleep -Milliseconds 25
                }
                [IO.File]::Exists($readyPath) | Should -BeTrue
                Start-Sleep -Milliseconds 300
                $process.HasExited | Should -BeFalse -Because 'the contender must wait for the shared owner-update namespace guard'
                [IO.File]::Delete($temporaryPath)
                $guard.Dispose()
                $guard = $null
                $process.WaitForExit(20000) | Should -BeTrue
                $process.ExitCode | Should -Be 0 -Because $stderr.Result
                $stdout.Result | Should -Not -Match 'BLOCKED'
            }
            finally {
                if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
                if ($guard) { $guard.Dispose() }
                if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                $process.Dispose()
            }
            return
        }

        $module = New-ModReservationGuardModuleForTest
        try {
            $repository = Join-Path $TestDrive 'mod-in-flight-other-owner'
            $lockRoot = Join-Path $repository 'AI Auto Update/In Progress/.locks/mod'
            [void][IO.Directory]::CreateDirectory($lockRoot)
            $firstKey = 'b' * 64
            $secondKey = 'c' * 64
            $firstPath = Join-Path $lockRoot "$firstKey.lock"
            $secondPath = Join-Path $lockRoot "$secondKey.lock"
            & $module {
                param($path, $root)
                Write-ModReservationOwner -ModLockPath $path -Repository $root -Value ([ordered]@{ seed = 'first' })
            } $firstPath $repository
            $guard = & $pathSafetyModuleObject {
                param($root, $leaf)
                Enter-PortableFileLock -Root $root `
                    -RelativeDirectory 'AI Auto Update/In Progress/.locks/mod' `
                    -Leaf $leaf -TimeoutMilliseconds 2000 `
                    -Label 'MOD in-flight owner test guard'
            } $repository "$firstKey.lock.owner-update.guard"
            $temporaryPath = Join-Path $lockRoot (".$firstKey.lock.publish-" + ('2' * 32) + '.tmp')
            [IO.File]::WriteAllText($temporaryPath, 'in-flight first MOD owner')
            try {
                & $module {
                    param($path, $root)
                    Write-ModReservationOwner -ModLockPath $path -Repository $root -Value ([ordered]@{ seed = 'second' })
                } $secondPath $repository
                Test-Path -LiteralPath $secondPath -PathType Leaf | Should -BeTrue
            }
            finally {
                if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
                $guard.Dispose()
            }
        }
        finally { Remove-Module $module -Force }
    }
}
