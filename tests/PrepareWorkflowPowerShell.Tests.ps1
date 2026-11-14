# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Offline workflow PowerShell preparation' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:preparePath = Join-Path $script:repoRoot 'scripts/Prepare-WorkflowPowerShell.ps1'
        $script:releaseModule = Import-Module (Join-Path $script:repoRoot 'scripts/PowerShellRelease.psm1') -Force -PassThru
        $script:platformRuntime = & $script:releaseModule { $script:PowerShellReleasePlatformRuntimeModule }
        Import-Module -ModuleInfo $script:platformRuntime -Force
        $script:platform = Get-PowerShellHostPlatform
        $script:architecture = Get-PowerShellHostArchitecture
        $script:executableName = Get-PowerShellExecutableName -Platform $script:platform
        $script:version = '7.6.6'
        $script:releaseTag = 'v7.6.6'
        $script:assetName = Get-PowerShellReleaseAssetName -Version $script:version `
            -Platform $script:platform -Architecture $script:architecture
        $script:assetTemplate = $script:assetName.Replace($script:version, '{0}')
        $global:S8Fix3CExecutableName = $script:executableName
        $global:S8Fix3CVersion = $script:version

        function New-WorkflowPowerShellFixture {
            param([Parameter(Mandatory)][string] $Root)

            [void][IO.Directory]::CreateDirectory($Root)
            $archivePath = Join-Path $Root $script:assetName
            [byte[]]$archiveBytes = [Text.UTF8Encoding]::new($false).GetBytes('offline PowerShell archive fixture')
            [IO.File]::WriteAllBytes($archivePath, $archiveBytes)
            $archiveSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveBytes)).ToLowerInvariant()
            $manifestPath = Join-Path $Root 'hashes.sha256'
            [byte[]]$manifestBody = [Text.UTF8Encoding]::new($false, $true).GetBytes("$archiveSha *$($script:assetName)`n")
            [IO.File]::WriteAllBytes($manifestPath, $manifestBody)
            $manifestSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBody)).ToLowerInvariant()
            $release = [pscustomobject]@{
                tag_name = $script:releaseTag
                draft = $false
                prerelease = $false
                assets = @(
                    [pscustomobject]@{
                        id = 101; name = $script:assetName; state = 'uploaded'; size = $archiveBytes.Length
                        digest = "sha256:$archiveSha"
                        browser_download_url = "https://github.com/PowerShell/PowerShell/releases/download/$($script:releaseTag)/$($script:assetName)"
                    }
                    [pscustomobject]@{
                        id = 102; name = 'hashes.sha256'; state = 'uploaded'; size = $manifestBody.Length
                        digest = "sha256:$manifestSha"
                        browser_download_url = "https://github.com/PowerShell/PowerShell/releases/download/$($script:releaseTag)/hashes.sha256"
                    }
                )
            }
            [pscustomobject]@{
                ArchivePath = $archivePath
                ArchiveBytes = $archiveBytes
                ArchiveSha = $archiveSha
                ManifestPath = $manifestPath
                ManifestBytes = $manifestBody
                ManifestSha = $manifestSha
                Release = $release
            }
        }

        function New-WorkflowInstallLayout {
            param([Parameter(Mandatory)][string] $Root)

            $cache = Join-Path $Root 'cache'
            $owned = Join-Path $Root 'owned'
            $artifacts = Join-Path $Root 'artifacts'
            foreach ($path in @($Root, $cache, $owned, $artifacts)) { [void][IO.Directory]::CreateDirectory($path) }
            [pscustomobject]@{
                Root = $Root
                Cache = $cache
                Owned = $owned
                Artifacts = $artifacts
                Runtime = Join-Path $Root ('runtime-' + [guid]::NewGuid().ToString('N'))
                GitHubEnvironment = Join-Path $Root 'github-env.txt'
                GitHubPath = Join-Path $Root 'github-path.txt'
            }
        }

        function Invoke-OfflineInstall {
            param(
                [Parameter(Mandatory)] $Fixture,
                [Parameter(Mandatory)] $Layout,
                [string] $ArchiveSha = $Fixture.ArchiveSha,
                [string] $ManifestSha = $Fixture.ManifestSha
            )

            Copy-Item -LiteralPath $Fixture.ArchivePath -Destination (Join-Path $Layout.Cache $script:assetName)
            Copy-Item -LiteralPath $Fixture.ManifestPath -Destination (Join-Path $Layout.Cache 'hashes.sha256')
            $env:GITHUB_ENV = $Layout.GitHubEnvironment
            $env:GITHUB_PATH = $Layout.GitHubPath
            & $script:preparePath -Mode Install -Platform $script:platform -ExpectedArchitecture $script:architecture `
                -ExecutableName $script:executableName -RuntimeRoot $Layout.Runtime -OwnedRoot $Layout.Owned `
                -ArtifactsRoot $Layout.Artifacts -CacheRoot $Layout.Cache -Version $script:version `
                -ReleaseTag $script:releaseTag -AssetName $script:assetName `
                -ArchiveUrl "https://github.com/PowerShell/PowerShell/releases/download/$($script:releaseTag)/$($script:assetName)" `
                -HashesUrl "https://github.com/PowerShell/PowerShell/releases/download/$($script:releaseTag)/hashes.sha256" `
                -OfficialArchiveSha256 $ArchiveSha -HashesManifestSha256 $ManifestSha `
                -FreshHashesPath $Fixture.ManifestPath
        }
    }

    AfterEach {
        foreach ($name in @(
            'GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_PATH', 'RUNNER_TEMP',
            'DT_POWERSHELL_EXECUTABLE', 'DT_POWERSHELL_VERSION', 'DT_POWERSHELL_ARCHIVE_SHA256'
        )) { [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process) }
    }

    AfterAll {
        Remove-Variable -Name S8Fix3CExecutableName -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name S8Fix3CVersion -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name S8Fix3CResolveFixture -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name S8Fix3CVerifyExecutable -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name S8Fix3CVerifyAliases -Scope Global -ErrorAction SilentlyContinue
    }

    # Scenario: Resolve consumes injected release metadata and manifest bytes without network access.
    # Purpose: Exercise the public Resolve mode and bind every emitted value to verified fixture evidence.
    It 'UnitT10_ResolvesInjectedReleaseMetadataAndRejectsManifestMismatch' {
        $fixture = New-WorkflowPowerShellFixture -Root (Join-Path $TestDrive 'resolve-fixture')
        $env:RUNNER_TEMP = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'resolve-output.txt'
        $global:S8Fix3CResolveFixture = $fixture
        Mock Invoke-WebRequest {
            param($Uri, $Headers, $OutFile, $MaximumRedirection, $TimeoutSec, $ErrorAction)
            if (-not [string]::IsNullOrWhiteSpace([string]$OutFile)) {
                [IO.File]::WriteAllBytes([string]$OutFile, $global:S8Fix3CResolveFixture.ManifestBytes)
                return
            }
            [pscustomobject]@{
                Content = $global:S8Fix3CResolveFixture.Release | ConvertTo-Json -Depth 8 -Compress
                BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' } }
            }
        }

        { & $script:preparePath -Mode Resolve -Platform $script:platform -ExpectedArchitecture $script:architecture `
                -ExecutableName $script:executableName -AssetTemplate $script:assetTemplate } | Should -Not -Throw
        $outputs = Get-Content -LiteralPath $env:GITHUB_OUTPUT
        $outputs | Should -Contain "version=$($script:version)"
        $outputs | Should -Contain "official_sha256=$($fixture.ArchiveSha)"
        $outputs | Should -Contain "hashes_sha256=$($fixture.ManifestSha)"

        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'resolve-mismatch-output.txt'
        $global:S8Fix3CResolveFixture.ManifestBytes = [Text.UTF8Encoding]::new($false).GetBytes('tampered manifest')
        { & $script:preparePath -Mode Resolve -Platform $script:platform -ExpectedArchitecture $script:architecture `
                -ExecutableName $script:executableName -AssetTemplate $script:assetTemplate } | Should -Throw
    }

    # Scenario: Install consumes a verified cache while extraction and the child version report are injected.
    # Purpose: Prove the mode writes a receipt only after archive, manifest, signature, version, and cleanup gates pass.
    It 'UnitT20_InstallsValidOfflineEvidenceAndWritesTheVerifiedReceipt' {
        $fixture = New-WorkflowPowerShellFixture -Root (Join-Path $TestDrive 'install-fixture')
        $layout = New-WorkflowInstallLayout -Root (Join-Path $TestDrive 'install-valid')
        Mock Expand-VerifiedPowerShellArchive {
            [void][IO.Directory]::CreateDirectory($DestinationPath)
            $path = Join-Path $DestinationPath $global:S8Fix3CExecutableName
            [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
            $path
        }
        Mock Assert-PowerShellExecutableSignature {
            [pscustomobject]@{ status = $(if ($IsWindows) { 'Valid' } else { $null }); signerSubject = $null; signerThumbprint = $null }
        }
        Mock Invoke-PowerShellReleaseOwnedProcess {
            [pscustomobject]@{ exitCode = 0; stdout = $global:S8Fix3CVersion; stderr = ''; cleanup = [pscustomobject]@{}; capturePath = 'fixture' }
        }

        { Invoke-OfflineInstall -Fixture $fixture -Layout $layout } | Should -Not -Throw
        $receiptPath = Join-Path $layout.Owned 'powershell-runtime-setup.json'
        Test-Path -LiteralPath $receiptPath -PathType Leaf | Should -BeTrue
        $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
        $receipt.observedArchiveSha256 | Should -BeExactly $fixture.ArchiveSha
        $receipt.cacheRestoredAndValid | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $layout.Runtime '.powershell-runtime-unusable.json') | Should -BeFalse
    }

    # Scenario: Either published digest disagrees with the injected archive or manifest.
    # Purpose: Reject both evidence mismatches before an extraction destination is created.
    It 'UnitT30_RejectsArchiveAndManifestDigestMismatch_<Case>' -ForEach @(
        @{ Case = 'archive'; ArchiveSha = ('0' * 64); ManifestSha = $null }
        @{ Case = 'manifest'; ArchiveSha = $null; ManifestSha = ('0' * 64) }
    ) {
        $fixture = New-WorkflowPowerShellFixture -Root (Join-Path $TestDrive "digest-fixture-$Case")
        $layout = New-WorkflowInstallLayout -Root (Join-Path $TestDrive "digest-layout-$Case")
        $archiveDigest = if ($null -eq $ArchiveSha) { $fixture.ArchiveSha } else { $ArchiveSha }
        $manifestDigest = if ($null -eq $ManifestSha) { $fixture.ManifestSha } else { $ManifestSha }
        { Invoke-OfflineInstall -Fixture $fixture -Layout $layout -ArchiveSha $archiveDigest -ManifestSha $manifestDigest } |
            Should -Throw
        Test-Path -LiteralPath $layout.Runtime | Should -BeFalse
    }

    # Scenario: A cache contains only one member of the archive/manifest pair.
    # Purpose: Treat partial cache state as pollution instead of overwriting or silently repairing it.
    It 'UnitT40_RejectsPartialCachePollution' {
        $fixture = New-WorkflowPowerShellFixture -Root (Join-Path $TestDrive 'pollution-fixture')
        $layout = New-WorkflowInstallLayout -Root (Join-Path $TestDrive 'pollution-layout')
        Copy-Item -LiteralPath $fixture.ArchivePath -Destination (Join-Path $layout.Cache $script:assetName)
        $env:GITHUB_ENV = $layout.GitHubEnvironment
        $env:GITHUB_PATH = $layout.GitHubPath
        { & $script:preparePath -Mode Install -Platform $script:platform -ExpectedArchitecture $script:architecture `
                -ExecutableName $script:executableName -RuntimeRoot $layout.Runtime -OwnedRoot $layout.Owned `
                -ArtifactsRoot $layout.Artifacts -CacheRoot $layout.Cache -Version $script:version `
                -ReleaseTag $script:releaseTag -AssetName $script:assetName -ArchiveUrl 'https://example.invalid/archive' `
                -HashesUrl 'https://example.invalid/hashes' -OfficialArchiveSha256 $fixture.ArchiveSha `
                -HashesManifestSha256 $fixture.ManifestSha -FreshHashesPath $fixture.ManifestPath } | Should -Throw
        Test-Path -LiteralPath $layout.Runtime | Should -BeFalse
    }

    # Scenario: The attempt-specific destination already exists and is non-empty.
    # Purpose: Refuse adoption without inspecting, clearing, or replacing the existing tree.
    It 'UnitT50_RejectsANonEmptyDestinationWithoutDeletingIt' {
        $fixture = New-WorkflowPowerShellFixture -Root (Join-Path $TestDrive 'nonempty-fixture')
        $layout = New-WorkflowInstallLayout -Root (Join-Path $TestDrive 'nonempty-layout')
        [void][IO.Directory]::CreateDirectory($layout.Runtime)
        [IO.File]::WriteAllText((Join-Path $layout.Runtime 'sentinel.txt'), 'preserve')
        { Invoke-OfflineInstall -Fixture $fixture -Layout $layout } | Should -Throw '*already exists*'
        [IO.File]::ReadAllText((Join-Path $layout.Runtime 'sentinel.txt')) | Should -BeExactly 'preserve'
    }

    # Scenario: The owned version probe reports uncertain cleanup after extraction.
    # Purpose: Fail closed, preserve the failed tree, mark it unusable, and require a new attempt name.
    It 'UnitT60_MarksTheDestinationUnusableWhenOwnedProcessCleanupFails' {
        $fixture = New-WorkflowPowerShellFixture -Root (Join-Path $TestDrive 'cleanup-fixture')
        $layout = New-WorkflowInstallLayout -Root (Join-Path $TestDrive 'cleanup-layout')
        Mock Expand-VerifiedPowerShellArchive {
            [void][IO.Directory]::CreateDirectory($DestinationPath)
            $path = Join-Path $DestinationPath $global:S8Fix3CExecutableName
            [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
            $path
        }
        Mock Assert-PowerShellExecutableSignature { [pscustomobject]@{ status = $null; signerSubject = $null; signerThumbprint = $null } }
        Mock Invoke-PowerShellReleaseOwnedProcess { throw 'Owned PowerShell process cleanup was incomplete or uncertain.' }

        { Invoke-OfflineInstall -Fixture $fixture -Layout $layout } | Should -Throw '*cleanup*'
        Test-Path -LiteralPath $layout.Runtime -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $layout.Runtime '.powershell-runtime-unusable.json') -PathType Leaf | Should -BeTrue
        $retryPath = Join-Path $layout.Root ('runtime-retry-' + [guid]::NewGuid().ToString('N'))
        $retryPath | Should -Not -BeExactly $layout.Runtime
        Test-Path -LiteralPath $retryPath | Should -BeFalse
    }

    # Scenario: Verify runs in the selected runtime, then receives a mismatched expected executable.
    # Purpose: Exercise both the valid Verify path and the runtime identity/path mismatch rejection.
    It 'UnitT70_VerifiesTheSelectedRuntimeAndRejectsIdentityMismatch' {
        $global:S8Fix3CVerifyExecutable = Join-Path $PSHOME $script:executableName
        $global:S8Fix3CVerifyAliases = @(
            [Environment]::ProcessPath,
            [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,
            (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source,
            $global:S8Fix3CVerifyExecutable
        )
        Mock Resolve-PlatformPhysicalPath {
            param($Path)
            $full = [IO.Path]::GetFullPath($Path)
            if (@($global:S8Fix3CVerifyAliases) -contains $full) { return $global:S8Fix3CVerifyExecutable }
            return $full
        }
        $env:DT_POWERSHELL_EXECUTABLE = $global:S8Fix3CVerifyExecutable
        $env:DT_POWERSHELL_VERSION = $PSVersionTable.PSVersion.ToString()
        $env:DT_POWERSHELL_ARCHIVE_SHA256 = 'a' * 64
        { & $script:preparePath -Mode Verify -Platform $script:platform -ExpectedArchitecture $script:architecture `
                -ExecutableName $script:executableName } | Should -Not -Throw

        $env:DT_POWERSHELL_EXECUTABLE = Join-Path $TestDrive $script:executableName
        [IO.File]::WriteAllBytes($env:DT_POWERSHELL_EXECUTABLE, [byte[]](1, 2, 3))
        { & $script:preparePath -Mode Verify -Platform $script:platform -ExpectedArchitecture $script:architecture `
                -ExecutableName $script:executableName } | Should -Throw '*not the verified PowerShell*'
        Remove-Variable -Name S8Fix3CVerifyExecutable -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name S8Fix3CVerifyAliases -Scope Global -ErrorAction SilentlyContinue
    }

    # Scenario: The shared process wrapper launches the current pwsh through an executable lease.
    # Purpose: Provide behavioral evidence for bounded owned-process launch and verified cleanup.
    It 'InterT80_LaunchesPowerShellThroughTheAuthorityOwnedProcess' {
        $workingPath = New-PlatformPrivateRoot -Parent $TestDrive -Leaf ('owned-process-' + [guid]::NewGuid().ToString('N'))
        $executablePath = [Environment]::ProcessPath
        $executableParent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($executablePath)) -RootOnly
        $executableLease = Open-PlatformFile -ParentLease $executableParent `
            -Leaf ([IO.Path]::GetFileName($executablePath)) -Access Read -CreateMode OpenExisting
        $workingLease = Open-PlatformDirectory -Root $workingPath -RootOnly
        try {
            $result = Invoke-PowerShellReleaseOwnedProcess -ExecutableLease $executableLease `
                -ExecutablePath $executablePath -WorkingDirectoryLease $workingLease `
                -WorkingDirectoryPath $workingPath -TimeoutSeconds 15 -ArgumentList @(
                    '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("authority-owned")'
                )
            $result.exitCode | Should -Be 0
            $result.stdout | Should -BeExactly 'authority-owned'
            $result.cleanup.CleanedUp | Should -BeTrue
            @($result.cleanup.RemainingPids).Count | Should -Be 0
        }
        finally {
            $workingLease.Dispose()
            $executableLease.Dispose()
            $executableParent.Dispose()
        }
    }

    # Scenario: The owned PowerShell root and its long-running descendant remain alive past a one-second deadline.
    # Purpose: Bound the real wrapper, reclaim the complete process tree, withhold success, and retain capture evidence.
    It 'InterT81_BoundsAHangingPowerShellTreeAndPreservesFailureEvidence' {
        $workingPath = New-PlatformPrivateRoot -Parent $TestDrive -Leaf ('owned-timeout-' + [guid]::NewGuid().ToString('N'))
        $successReceiptPath = Join-Path $workingPath 'fixture-success-receipt.json'
        $executablePath = [Environment]::ProcessPath
        $executableParent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($executablePath)) -RootOnly
        $executableLease = Open-PlatformFile -ParentLease $executableParent `
            -Leaf ([IO.Path]::GetFileName($executablePath)) -Access Read -CreateMode OpenExisting
        $workingLease = Open-PlatformDirectory -Root $workingPath -RootOnly
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $fixtureCommand = @'
[Console]::Out.WriteLine('timeout-failure-evidence')
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = [Environment]::ProcessPath
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30')) {
    [void]$info.ArgumentList.Add($argument)
}
$descendant = [Diagnostics.Process]::Start($info)
[Console]::Out.WriteLine($descendant.Id)
Start-Sleep -Seconds 30
'@
            $failure = { Invoke-PowerShellReleaseOwnedProcess -ExecutableLease $executableLease `
                    -ExecutablePath $executablePath -WorkingDirectoryLease $workingLease `
                    -WorkingDirectoryPath $workingPath -TimeoutSeconds 1 -ArgumentList @(
                        '-NoProfile', '-NonInteractive', '-Command', $fixtureCommand
                    ) } | Should -Throw '*exceeded its 1 second deadline*' -PassThru
            if ($null -eq $failure) {
                [IO.File]::WriteAllText($successReceiptPath, '{"result":"passed"}')
            }
        }
        finally {
            $stopwatch.Stop()
            $workingLease.Dispose()
            $executableLease.Dispose()
            $executableParent.Dispose()
        }

        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
        $failure.Exception | Should -BeOfType ([TimeoutException])
        Test-Path -LiteralPath $successReceiptPath | Should -BeFalse
        [string]$failure.Exception.Data['Stdout'] | Should -Match 'timeout-failure-evidence'
        $descendantId = [int](@(([string]$failure.Exception.Data['Stdout']) -split '\r?\n' | Where-Object { $_ -match '^\d+$' })[0])
        Get-Process -Id $descendantId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $failure.Exception.Data['CleanupReceipt'].CleanedUp | Should -BeTrue
        @($failure.Exception.Data['CleanupReceipt'].RemainingPids).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path ([string]$failure.Exception.Data['CapturePath']) 'stdout.txt') -PathType Leaf | Should -BeTrue
    }

    # Scenario: Native cleanup completes, but the boundary receives either an unstopped reader or a reported remaining PID.
    # Purpose: Reject every incomplete receipt without mocking the wrapper or losing its retained stdout failure evidence.
    It 'InterT82_RejectsIncompleteOwnedProcessCleanupReceipt_<Fault>' -ForEach @(
        @{ Fault = 'CaptureReadersStopped' }
        @{ Fault = 'RemainingPids' }
    ) {
        $workingPath = New-PlatformPrivateRoot -Parent $TestDrive -Leaf ("owned-cleanup-$Fault-" + [guid]::NewGuid().ToString('N'))
        $successReceiptPath = Join-Path $workingPath 'fixture-success-receipt.json'
        $executablePath = [Environment]::ProcessPath
        $executableParent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($executablePath)) -RootOnly
        $executableLease = Open-PlatformFile -ParentLease $executableParent `
            -Leaf ([IO.Path]::GetFileName($executablePath)) -Access Read -CreateMode OpenExisting
        $workingLease = Open-PlatformDirectory -Root $workingPath -RootOnly
        $global:S8Fix4CCleanupFault = $Fault
        Mock Stop-PlatformOwnedProcess -ModuleName $script:releaseModule.Name {
            param($Lease, $ExpectedStartIdentity, $Deadline)
            $actual = $Lease.Stop([TimeSpan]::FromMilliseconds(250), $Deadline, $ExpectedStartIdentity)
            [pscustomobject][ordered]@{
                CleanedUp = [bool]$actual.CleanedUp
                CaptureReadersStopped = if ($global:S8Fix4CCleanupFault -ceq 'CaptureReadersStopped') { $false } else { [bool]$actual.CaptureReadersStopped }
                CaptureResourcesClosed = [bool]$actual.CaptureResourcesClosed
                RemainingPids = if ($global:S8Fix4CCleanupFault -ceq 'RemainingPids') { [int[]]@($PID) } else { [int[]]@($actual.RemainingPids) }
                Uncertainty = $actual.Uncertainty
            }
        }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $failure = { Invoke-PowerShellReleaseOwnedProcess -ExecutableLease $executableLease `
                    -ExecutablePath $executablePath -WorkingDirectoryLease $workingLease `
                    -WorkingDirectoryPath $workingPath -TimeoutSeconds 5 -ArgumentList @(
                        '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write("cleanup-failure-evidence"); exit 0'
                    ) } | Should -Throw '*cleanup was incomplete or uncertain*' -PassThru
            if ($null -eq $failure) {
                [IO.File]::WriteAllText($successReceiptPath, '{"result":"passed"}')
            }
        }
        finally {
            $stopwatch.Stop()
            $workingLease.Dispose()
            $executableLease.Dispose()
            $executableParent.Dispose()
            Remove-Variable -Name S8Fix4CCleanupFault -Scope Global -ErrorAction SilentlyContinue
        }

        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
        $failure.Exception.Message | Should -Match 'cleanup was incomplete or uncertain'
        Test-Path -LiteralPath $successReceiptPath | Should -BeFalse
        $captureDirectory = @(Get-ChildItem -LiteralPath $workingPath -Directory -Filter '.owned-process-*')
        $captureDirectory.Count | Should -Be 1
        Get-Content -Raw -LiteralPath (Join-Path $captureDirectory[0].FullName 'stdout.txt') |
            Should -BeExactly 'cleanup-failure-evidence'
    }
}
