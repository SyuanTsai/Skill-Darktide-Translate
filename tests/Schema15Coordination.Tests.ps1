# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Schema 15 multi-process coordination contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $skillRoot = Join-Path $repoRoot 'skills/auto-update-darktide-mod'
        $scriptRoot = Join-Path $skillRoot 'scripts'
        $runnerPath = Join-Path $scriptRoot 'mod-update.ps1'
        $coordinationModule = Join-Path $scriptRoot 'SharedCoordinationLock.psm1'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
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

    It 'InterT180_SerializesTwoModsAndRejectsACompetingGenerationAcrossProcesses' -Tag 'MultiProcess' {
        $repository = Join-Path $TestDrive 'multi-process-repository'
        $modsRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods'
        $queueRoot = Join-Path $repository 'AI Auto Update'
        New-Item -ItemType Directory -Path (Join-Path $modsRoot 'ModA'), (Join-Path $modsRoot 'ModB'), $queueRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $modsRoot 'ModA/a.txt'), 'old-a', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $modsRoot 'ModB/b.txt'), 'old-b', [Text.UTF8Encoding]::new($false))
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Coordination Test'
        & git -C $repository config user.email 'coordination@example.invalid'
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'coordination fixture base'

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
                '-SkillSourcePinPath', $script:skillSourcePinPath, '-BaseRef', 'HEAD'
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
            $successful.Count | Should -Be 2
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
                $owner = Get-Content -LiteralPath (Join-Path ([string]$state.modLockPath) 'owner.json') -Raw | ConvertFrom-TestJson -AsHashtable
                [string]$owner.leaseMode | Should -Be 'reserved'
                [string]$owner.workerToken | Should -BeNullOrEmpty
                $owner.workerId | Should -BeNullOrEmpty
                $owner.workerProcessStartTicks | Should -BeNullOrEmpty
                @($state.coordinationReceipts.resourceKey) | Should -Contain 'source-acquisition'
                @($state.coordinationReceipts.resourceKey) | Should -Contain 'git-coordination'
            }
            @(Get-ChildItem -LiteralPath (Join-Path $queueRoot '.claims') -Directory).Count | Should -Be 2
            @(Get-ChildItem -LiteralPath (Join-Path $queueRoot 'In Progress/.locks/mod') -Directory).Count | Should -Be 2

            $receipts = @($states.coordinationReceipts | ForEach-Object {
                Get-Content -LiteralPath ([string]$_.path) -Raw | ConvertFrom-TestJson -AsHashtable
            })
            foreach ($resourceKey in @('source-acquisition', 'git-coordination')) {
                $timeline = @($receipts | Where-Object { $_.resourceKey -ceq $resourceKey } | Sort-Object { [DateTimeOffset]$_.acquiredAt })
                for ($index = 1; $index -lt $timeline.Count; $index++) {
                    [DateTimeOffset]$timeline[$index].acquiredAt | Should -BeGreaterOrEqual ([DateTimeOffset]$timeline[$index - 1].completedAt)
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

    It 'InterT181_RetainsStaleEvidenceAndPreventsAnOldTokenFromDeletingTheNewOwner' {
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
        $ownerPath = Join-Path ([string]$oldLease.path) 'owner.json'
        $oldOwner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-TestJson -AsHashtable
        $oldOwner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
        $oldOwner | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerPath -NoNewline

        $newLease = Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'source-acquisition' `
            -RunId '18181818-5555-4555-8555-555555555555' -ReceiptRoot $receiptRoot
        try {
            [string]$newLease.staleEvidencePath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath ([string]$newLease.staleEvidencePath) -PathType Container | Should -BeTrue
            { Exit-SharedCoordinationLease -Lease $oldLease } | Should -Throw '*ownership changed*'
            Test-Path -LiteralPath ([string]$newLease.path) -PathType Container | Should -BeTrue
            $newOwner = Get-Content -LiteralPath (Join-Path ([string]$newLease.path) 'owner.json') -Raw | ConvertFrom-TestJson -AsHashtable
            [string]$newOwner.token | Should -Be ([string]$newLease.token)
            $beforeHeartbeat = [DateTimeOffset]$newOwner.heartbeat
            Start-Sleep -Milliseconds 20
            Update-SharedCoordinationLease -Lease $newLease -Force
            $refreshedOwner = Get-Content -LiteralPath (Join-Path ([string]$newLease.path) 'owner.json') -Raw | ConvertFrom-TestJson -AsHashtable
            [DateTimeOffset]$refreshedOwner.heartbeat | Should -BeGreaterThan $beforeHeartbeat
        }
        finally {
            $receipt = Exit-SharedCoordinationLease -Lease $newLease
        }
        Test-Path -LiteralPath ([string]$newLease.path) | Should -BeFalse
        $receiptRecord = Get-Content -LiteralPath ([string]$receipt.path) -Raw | ConvertFrom-TestJson -AsHashtable
        [string]$receiptRecord.staleEvidencePath | Should -Be ([string]$newLease.staleEvidencePath)
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

            $ownerPath = Join-Path ([string]$lease.path) 'owner.json'
            $validOwnerJson = Get-Content -LiteralPath $ownerPath -Raw
            try {
                $malformedOwner = $validOwnerJson | ConvertFrom-TestJson -AsHashtable
                $malformedOwner.processStartTicks = 'not-a-number'
                $malformedOwner.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')
                $malformedOwner | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerPath -NoNewline
                { Enter-SharedCoordinationLease -RepositoryRoot $repository -ResourceKey 'git-coordination' `
                    -RunId '18218218-4182-4182-8182-182182182182' -TimeoutSeconds 1 } |
                    Should -Throw '*owner contract is invalid*'
                Test-Path -LiteralPath ([string]$lease.path) -PathType Container | Should -BeTrue
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
}
