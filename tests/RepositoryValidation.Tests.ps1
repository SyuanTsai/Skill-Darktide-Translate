# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Repository pre-push validation' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:stateValidatorPath = Join-Path $script:repoRoot 'scripts/Test-CleanRepositoryHead.ps1'
        $script:prePushPath = Join-Path $script:repoRoot 'scripts/Invoke-PrePushValidation.ps1'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:layout = Get-TestRepositoryLayout -RepositoryRoot $script:repoRoot

        function New-TestGitRepository {
            param([string] $Path)

            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            & git -C $Path init --quiet --initial-branch=main
            if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the test repository.' }
            & git -C $Path config user.name 'Repository Validation Test'
            & git -C $Path config user.email 'repository-validation@example.invalid'
            Set-Content -LiteralPath (Join-Path $Path 'tracked.txt') -Value 'committed'
            & git -C $Path add -- tracked.txt
            & git -C $Path commit --quiet -m 'test fixture'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to commit the test repository fixture.' }
        }
    }

    It 'UnitT10_AcceptsOnlyACleanRepositoryAndReturnsItsExactHead' {
        Test-Path -LiteralPath $script:stateValidatorPath | Should -Be $true
        $fixtureRoot = Join-Path $TestDrive 'clean'
        New-TestGitRepository -Path $fixtureRoot

        $result = & $script:stateValidatorPath -RepositoryRoot $fixtureRoot -PassThru
        $expectedHead = (& git -C $fixtureRoot rev-parse --verify 'HEAD^{commit}').Trim()

        $result.result | Should -Be 'passed'
        $result.repositoryRoot | Should -Be (Resolve-Path -LiteralPath $fixtureRoot).Path
        $result.headOid | Should -Be $expectedHead
    }

    It 'UnitT20_RejectsTrackedAndUntrackedChangesBeforeValidation' -ForEach @(
        @{ Case = 'tracked'; Mutate = { param($root) Set-Content -LiteralPath (Join-Path $root 'tracked.txt') -Value 'changed' } }
        @{ Case = 'untracked'; Mutate = { param($root) Set-Content -LiteralPath (Join-Path $root 'untracked.txt') -Value 'new' } }
    ) {
        $fixtureRoot = Join-Path $TestDrive $Case
        New-TestGitRepository -Path $fixtureRoot
        & $Mutate $fixtureRoot

        { & $script:stateValidatorPath -RepositoryRoot $fixtureRoot -PassThru } |
            Should -Throw '*working tree and index must be clean*'
    }

    It 'UnitT30_RejectsAHeadThatChangedAfterValidationStarted' {
        $fixtureRoot = Join-Path $TestDrive 'head-drift'
        New-TestGitRepository -Path $fixtureRoot

        { & $script:stateValidatorPath -RepositoryRoot $fixtureRoot `
                -ExpectedHeadOid '0000000000000000000000000000000000000000' -PassThru } |
            Should -Throw '*HEAD changed during pre-push validation*'
    }

    # Scenario: The caller reaches the repository through a linked alias, as macOS does for /var -> /private/var.
    # Purpose: Compare physical paths on both sides so an alias of the exact root is accepted while subdirectories stay rejected.
    It 'UnitT35_ComparesPhysicalRepositoryRootsOnBothSides' {
        $fixtureRoot = Join-Path $TestDrive 'physical-root'
        New-TestGitRepository -Path $fixtureRoot
        $aliasRoot = Join-Path $TestDrive 'linked-alias'
        New-TestReparsePoint -Path $aliasRoot -Target $fixtureRoot | Out-Null

        $result = & $script:stateValidatorPath -RepositoryRoot $aliasRoot -PassThru
        $result.result | Should -Be 'passed'
        $result.repositoryRoot | Should -Be (Resolve-Path -LiteralPath $aliasRoot).Path
        $result.headOid | Should -Be (& git -C $fixtureRoot rev-parse --verify 'HEAD^{commit}').Trim()

        $subdirectory = Join-Path $fixtureRoot 'nested'
        New-Item -ItemType Directory -Path $subdirectory | Out-Null
        { & $script:stateValidatorPath -RepositoryRoot $subdirectory -PassThru } |
            Should -Throw '*must be the Git repository root*'
        { & $script:stateValidatorPath -RepositoryRoot (Join-Path $aliasRoot 'nested') -PassThru } |
            Should -Throw '*must be the Git repository root*'
    }

    # Scenario: The Standard v1 source tree is validated through its documented entry points.
    # Purpose: Keep the local pre-push wrapper bound to the canonical validator and its comparison inputs.
    It 'UnitT40_UsesTheValidationEntrypointForThePrePushWrapper' {
        Test-Path -LiteralPath $script:prePushPath | Should -BeTrue
        $prePush = Get-Content -LiteralPath $script:prePushPath -Raw
        $prePush | Should -Match 'scripts/Validate\.ps1'
        $prePush | Should -Match 'ArtifactsRoot'
        $prePush | Should -Match 'BaseCommit'
        $prePush | Should -Not -Match 'tests/Invoke-Tests\.ps1'
        $prePush | Should -Not -Match 'Test-ReferenceIntegrity\.ps1'
    }
}

Describe 'Latest stable PowerShell release evidence' {
    BeforeAll {
        $script:releaseModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/PowerShellRelease.psm1'
        if (Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf) {
            Import-Module $script:releaseModulePath -Force
        }

        function New-LatestPowerShellReleaseFixture {
            param(
                [string] $Digest = ('sha256:' + ('a' * 64)),
                [long] $Size = 9,
                [string] $AssetName = 'PowerShell-7.6.6-win-x64.zip',
                [string] $HashesDigest = ('sha256:' + ('b' * 64)),
                [long] $HashesSize = 128,
                [switch] $WithoutHashesManifest
            )
            $assets = [Collections.Generic.List[object]]::new()
            $assets.Add([pscustomobject]@{
                id = 766
                name = $AssetName
                state = 'uploaded'
                size = $Size
                digest = $Digest
                browser_download_url = "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/$AssetName"
            })
            if (-not $WithoutHashesManifest) {
                $assets.Add([pscustomobject]@{
                    id = 767
                    name = 'hashes.sha256'
                    state = 'uploaded'
                    size = $HashesSize
                    digest = $HashesDigest
                    browser_download_url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/hashes.sha256'
                })
            }
            [pscustomobject]@{
                tag_name = 'v7.6.6'
                draft = $false
                prerelease = $false
                assets = $assets.ToArray()
            }
        }

        function New-PowerShellHashesManifestFixture {
            param(
                [Parameter(Mandatory)][string] $Path,
                [Parameter(Mandatory)][string[]] $Lines
            )
            [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
            $item = Get-Item -LiteralPath $Path
            [pscustomobject]@{
                Digest = 'sha256:' + (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
                Size = [long]$item.Length
            }
        }

        function New-TestTarGzArchive {
            param(
                [Parameter(Mandatory)][string] $Path,
                [Parameter(Mandatory)][object[]] $Entries
            )
            Add-Type -AssemblyName System.Formats.Tar
            $file = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Optimal, $true)
                try {
                    $writer = [Formats.Tar.TarWriter]::new($gzip, [Formats.Tar.TarEntryFormat]::Ustar, $true)
                    try {
                        foreach ($entrySpec in $Entries) {
                            $entry = [Formats.Tar.UstarTarEntry]::new([Formats.Tar.TarEntryType]::RegularFile, [string]$entrySpec.Name)
                            $entry.Mode = [IO.UnixFileMode]$entrySpec.Mode
                            $entry.DataStream = [IO.MemoryStream]::new([Text.UTF8Encoding]::new($false).GetBytes([string]$entrySpec.Content))
                            $writer.WriteEntry($entry)
                        }
                    }
                    finally { $writer.Dispose() }
                }
                finally { $gzip.Dispose() }
            }
            finally { $file.Dispose() }
        }

        function New-HostPowerShellArchiveAsset {
            param([Parameter(Mandatory)][string] $ArchivePath)
            $platform = Get-PowerShellHostPlatform
            $architecture = Get-PowerShellHostArchitecture
            $assetName = Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform $platform -Architecture $architecture
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
            $release = New-LatestPowerShellReleaseFixture -AssetName $assetName -Digest "sha256:$hash" -Size (Get-Item -LiteralPath $ArchivePath).Length
            Get-VerifiedPowerShellReleaseAsset -Release $release -Platform $platform -Architecture $architecture
        }
    }

    # Scenario: The Microsoft stable channel resolves to one stable Windows x64 release archive.
    # Purpose: Bind the selected runtime to the official redirect tag, exact asset identity, published SHA-256 digest, and hash manifest.
    It 'UnitT70_AcceptsOneStableDigestBoundX64Archive' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $asset = Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture) -Platform windows -Architecture x64

        $asset.version | Should -BeExactly '7.6.6'
        $asset.tag | Should -BeExactly 'v7.6.6'
        $asset.platform | Should -BeExactly 'windows'
        $asset.architecture | Should -BeExactly 'x64'
        $asset.executableName | Should -BeExactly 'pwsh.exe'
        $asset.name | Should -BeExactly 'PowerShell-7.6.6-win-x64.zip'
        $asset.digest | Should -BeExactly ('sha256:' + ('a' * 64))
        $asset.browserDownloadUrl | Should -BeExactly 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip'
        $asset.hashesManifest.name | Should -BeExactly 'hashes.sha256'
        $asset.hashesManifest.digest | Should -BeExactly ('sha256:' + ('b' * 64))
        $asset.hashesManifest.browserDownloadUrl | Should -BeExactly 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/hashes.sha256'
    }

    # Scenario: Each supported operating system and architecture selects its own official archive.
    # Purpose: Bind Windows to the zip with pwsh.exe and Linux/macOS to the tar.gz with pwsh, rejecting other targets.
    It 'UnitT71_SelectsThePlatformArchiveAndExecutableName' -ForEach @(
        @{ Platform = 'windows'; Architecture = 'x64'; AssetName = 'PowerShell-7.6.6-win-x64.zip'; ExecutableName = 'pwsh.exe' }
        @{ Platform = 'windows'; Architecture = 'arm64'; AssetName = 'PowerShell-7.6.6-win-arm64.zip'; ExecutableName = 'pwsh.exe' }
        @{ Platform = 'linux'; Architecture = 'x64'; AssetName = 'powershell-7.6.6-linux-x64.tar.gz'; ExecutableName = 'pwsh' }
        @{ Platform = 'linux'; Architecture = 'arm64'; AssetName = 'powershell-7.6.6-linux-arm64.tar.gz'; ExecutableName = 'pwsh' }
        @{ Platform = 'macos'; Architecture = 'x64'; AssetName = 'powershell-7.6.6-osx-x64.tar.gz'; ExecutableName = 'pwsh' }
        @{ Platform = 'macos'; Architecture = 'arm64'; AssetName = 'powershell-7.6.6-osx-arm64.tar.gz'; ExecutableName = 'pwsh' }
    ) {
        Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform $Platform -Architecture $Architecture | Should -BeExactly $AssetName
        Get-PowerShellExecutableName -Platform $Platform | Should -BeExactly $ExecutableName

        $asset = Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture -AssetName $AssetName) -Platform $Platform -Architecture $Architecture
        $asset.name | Should -BeExactly $AssetName
        $asset.platform | Should -BeExactly $Platform
        $asset.architecture | Should -BeExactly $Architecture
        $asset.executableName | Should -BeExactly $ExecutableName
        $asset.browserDownloadUrl | Should -BeExactly "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/$AssetName"

        # A release that only publishes another target's archive must not satisfy this target.
        $otherName = if ($Platform -ceq 'windows') { "powershell-7.6.6-linux-$Architecture.tar.gz" } else { "PowerShell-7.6.6-win-$Architecture.zip" }
        { Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture -AssetName $otherName) -Platform $Platform -Architecture $Architecture } |
            Should -Throw "*exactly one '$AssetName'*"
    }

    # Scenario: The installer runs on the current host without explicit target arguments.
    # Purpose: Derive the target from the operating system and RuntimeInformation.OSArchitecture, and reject unsupported targets.
    It 'UnitT72_DerivesTheDefaultTargetFromTheHostAndRejectsUnsupportedTargets' {
        $expectedPlatform = if ($IsWindows) { 'windows' } elseif ($IsLinux) { 'linux' } else { 'macos' }
        $expectedArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        Get-PowerShellHostPlatform | Should -BeExactly $expectedPlatform
        Get-PowerShellHostArchitecture | Should -BeExactly $expectedArchitecture

        $hostAssetName = Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform $expectedPlatform -Architecture $expectedArchitecture
        $asset = Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture -AssetName $hostAssetName)
        $asset.name | Should -BeExactly $hostAssetName
        $asset.platform | Should -BeExactly $expectedPlatform
        $asset.architecture | Should -BeExactly $expectedArchitecture

        { Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform 'freebsd' -Architecture 'x64' } | Should -Throw
        { Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform 'linux' -Architecture 'x86' } | Should -Throw
        { Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform 'Linux' -Architecture 'x64' } | Should -Throw
        { Get-PowerShellExecutableName -Platform 'freebsd' } | Should -Throw
        { Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture) -Platform windows -Architecture arm } | Should -Throw
    }

    # Scenario: Microsoft's stable alias resolves to the canonical GitHub tag whose metadata is fetched.
    # Purpose: Prevent a moving latest-release endpoint from selecting a channel that differs from Microsoft stable.
    It 'UnitT65_BindsReleaseMetadataToTheExactStableChannelRedirect' {
        $stableUri = [uri]'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6'
        $tag = Get-VerifiedPowerShellStableTagFromUri -ResolvedReleaseUri $stableUri
        $tag | Should -BeExactly 'v7.6.6'

        $release = New-LatestPowerShellReleaseFixture
        (Assert-PowerShellReleaseTagMatchesStableChannel -ExpectedTag $tag -Release $release) | Should -BeExactly $tag

        $mismatchedRelease = New-LatestPowerShellReleaseFixture
        $mismatchedRelease.tag_name = 'v7.6.5'
        { Assert-PowerShellReleaseTagMatchesStableChannel -ExpectedTag $tag -Release $mismatchedRelease } | Should -Throw

        foreach ($invalidUri in @(
            [uri]'https://aka.ms/powershell-release?tag=stable',
            [uri]'https://github.com.evil.example/PowerShell/PowerShell/releases/tag/v7.6.6',
            [uri]'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6?channel=stable',
            [uri]'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6-rc.1'
        )) {
            { Get-VerifiedPowerShellStableTagFromUri -ResolvedReleaseUri $invalidUri } | Should -Throw
        }
    }

    # Scenario: Release metadata is draft, prerelease, or uses a malformed/non-stable tag.
    # Purpose: Fail closed instead of resolving a preview or ambiguous PowerShell version.
    It 'UnitT80_RejectsDraftPrereleaseAndMalformedReleaseTags' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $draft = New-LatestPowerShellReleaseFixture
        $draft.draft = $true
        { Get-VerifiedPowerShellReleaseAsset -Release $draft -Platform windows -Architecture x64 } | Should -Throw

        $preview = New-LatestPowerShellReleaseFixture
        $preview.prerelease = $true
        { Get-VerifiedPowerShellReleaseAsset -Release $preview -Platform windows -Architecture x64 } | Should -Throw

        $malformed = New-LatestPowerShellReleaseFixture
        $malformed.tag_name = 'v7.6.6-rc.1'
        { Get-VerifiedPowerShellReleaseAsset -Release $malformed -Platform windows -Architecture x64 } | Should -Throw
    }

    # Scenario: The endpoint omits required archive or hash-manifest evidence or contains duplicate candidates.
    # Purpose: Reject missing digests, zero-length assets, a missing hashes.sha256, and ambiguous archive selection.
    It 'UnitT90_RejectsMissingDuplicateAndMalformedArchiveMetadata' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $missingDigest = New-LatestPowerShellReleaseFixture
        $missingDigest.assets[0].digest = $null
        { Get-VerifiedPowerShellReleaseAsset -Release $missingDigest -Platform windows -Architecture x64 } | Should -Throw

        $emptyAsset = New-LatestPowerShellReleaseFixture -Size 0
        { Get-VerifiedPowerShellReleaseAsset -Release $emptyAsset -Platform windows -Architecture x64 } | Should -Throw

        $duplicate = New-LatestPowerShellReleaseFixture
        $duplicate.assets = @($duplicate.assets[0], $duplicate.assets[0], $duplicate.assets[1])
        { Get-VerifiedPowerShellReleaseAsset -Release $duplicate -Platform windows -Architecture x64 } | Should -Throw

        $missingManifest = New-LatestPowerShellReleaseFixture -WithoutHashesManifest
        { Get-VerifiedPowerShellReleaseAsset -Release $missingManifest -Platform windows -Architecture x64 } | Should -Throw "*exactly one 'hashes.sha256'*"

        $manifestWithoutDigest = New-LatestPowerShellReleaseFixture
        $manifestWithoutDigest.assets[1].digest = $null
        { Get-VerifiedPowerShellReleaseAsset -Release $manifestWithoutDigest -Platform windows -Architecture x64 } | Should -Throw

        $manifestWrongUrl = New-LatestPowerShellReleaseFixture
        $manifestWrongUrl.assets[1].browser_download_url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/hashes.sha256'
        { Get-VerifiedPowerShellReleaseAsset -Release $manifestWrongUrl -Platform windows -Architecture x64 } | Should -Throw
    }

    # Scenario: Downloaded archive bytes or the executable's reported version disagree with release metadata.
    # Purpose: Reject tampering and ensure the validator starts only the release selected by Microsoft's stable alias.
    It 'UnitT100_RejectsMismatchedArchiveBytesAndRuntimeVersion' {
        Test-Path -LiteralPath $script:releaseModulePath -PathType Leaf | Should -BeTrue
        $archivePath = Join-Path $TestDrive 'PowerShell-7.6.6-win-x64.zip'
        $archiveBytes = [Text.UTF8Encoding]::new($false).GetBytes('archive fixture')
        [IO.File]::WriteAllBytes($archivePath, $archiveBytes)
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
        $release = New-LatestPowerShellReleaseFixture -Digest "sha256:$hash" -Size $archiveBytes.Length
        $asset = Get-VerifiedPowerShellReleaseAsset -Release $release -Platform windows -Architecture x64

        (Assert-VerifiedPowerShellArchive -Asset $asset -Path $archivePath) | Should -BeExactly $hash
        { Assert-PowerShellRuntimeVersion -Tag $asset.tag -ActualVersion '7.6.5' } | Should -Throw

        [IO.File]::WriteAllText($archivePath, 'tampered archive', [Text.UTF8Encoding]::new($false))
        { Assert-VerifiedPowerShellArchive -Asset $asset -Path $archivePath } | Should -Throw
    }

    # Scenario: The official hashes.sha256 is downloaded next to the archive.
    # Purpose: Require its bytes to match the API digest and its archive entry to equal the archive API digest.
    It 'UnitT105_BindsTheArchiveDigestToTheOfficialHashManifest' {
        $archiveHash = 'c' * 64
        $otherHash = 'd' * 64
        $manifestPath = Join-Path $TestDrive 'hashes.sha256'
        $manifest = New-PowerShellHashesManifestFixture -Path $manifestPath -Lines @(
            "$($otherHash.ToUpperInvariant()) *powershell-7.6.6-linux-x64.tar.gz"
            "$archiveHash *PowerShell-7.6.6-win-x64.zip"
        )
        $release = New-LatestPowerShellReleaseFixture -Digest "sha256:$archiveHash" -HashesDigest $manifest.Digest -HashesSize $manifest.Size
        $asset = Get-VerifiedPowerShellReleaseAsset -Release $release -Platform windows -Architecture x64
        (Assert-VerifiedPowerShellHashesManifest -Asset $asset -Path $manifestPath) | Should -BeExactly $manifest.Digest.Substring(7)
        Get-OfficialPowerShellManifestDigest -Path $manifestPath -ArchiveName 'powershell-7.6.6-linux-x64.tar.gz' | Should -BeExactly $otherHash

        # The archive API digest differs from the manifest entry.
        $mismatchedRelease = New-LatestPowerShellReleaseFixture -Digest "sha256:$otherHash" -HashesDigest $manifest.Digest -HashesSize $manifest.Size
        $mismatchedAsset = Get-VerifiedPowerShellReleaseAsset -Release $mismatchedRelease -Platform windows -Architecture x64
        { Assert-VerifiedPowerShellHashesManifest -Asset $mismatchedAsset -Path $manifestPath } | Should -Throw '*differs from the official hash manifest*'

        # The manifest has no entry, or more than one entry, for the selected archive.
        $missingPath = Join-Path $TestDrive 'hashes-missing.sha256'
        $missing = New-PowerShellHashesManifestFixture -Path $missingPath -Lines @("$otherHash *powershell-7.6.6-linux-x64.tar.gz")
        $missingRelease = New-LatestPowerShellReleaseFixture -Digest "sha256:$archiveHash" -HashesDigest $missing.Digest -HashesSize $missing.Size
        $missingAsset = Get-VerifiedPowerShellReleaseAsset -Release $missingRelease -Platform windows -Architecture x64
        { Assert-VerifiedPowerShellHashesManifest -Asset $missingAsset -Path $missingPath } | Should -Throw '*exactly one*'
        $duplicatePath = Join-Path $TestDrive 'hashes-duplicate.sha256'
        $duplicate = New-PowerShellHashesManifestFixture -Path $duplicatePath -Lines @("$archiveHash *PowerShell-7.6.6-win-x64.zip", "$archiveHash  PowerShell-7.6.6-win-x64.zip")
        $duplicateRelease = New-LatestPowerShellReleaseFixture -Digest "sha256:$archiveHash" -HashesDigest $duplicate.Digest -HashesSize $duplicate.Size
        $duplicateAsset = Get-VerifiedPowerShellReleaseAsset -Release $duplicateRelease -Platform windows -Architecture x64
        { Assert-VerifiedPowerShellHashesManifest -Asset $duplicateAsset -Path $duplicatePath } | Should -Throw '*exactly one*'

        # The manifest bytes were altered after the API digest was published.
        [IO.File]::AppendAllText($manifestPath, "# appended`n", [Text.UTF8Encoding]::new($false))
        { Assert-VerifiedPowerShellHashesManifest -Asset $asset -Path $manifestPath } | Should -Throw
    }

    # Register only on the native host: Windows archives are zip files whose pwsh.exe carries an Authenticode signature.
    if ($IsWindows) {
        # Scenario: A verified Windows archive is expanded and its executable signature is checked.
        # Purpose: Require pwsh.exe at the archive root and reject unsigned executables while accepting Microsoft-signed pwsh.exe.
        It 'UnitT110_ExpandsTheWindowsZipAndRequiresAMicrosoftAuthenticodeSignature' {
            $stagingRoot = Join-Path $TestDrive 'windows-staging'
            New-Item -ItemType Directory -Path $stagingRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $stagingRoot 'pwsh.exe'), 'unsigned executable fixture', [Text.UTF8Encoding]::new($false))
            $archivePath = Join-Path $TestDrive 'windows-runtime.zip'
            Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $archivePath
            $asset = New-HostPowerShellArchiveAsset -ArchivePath $archivePath

            $runtimeRoot = Join-Path $TestDrive 'windows-runtime'
            $executablePath = Expand-VerifiedPowerShellArchive -Asset $asset -ArchivePath $archivePath -DestinationPath $runtimeRoot
            $executablePath | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $runtimeRoot 'pwsh.exe')))
            [IO.File]::ReadAllText($executablePath) | Should -BeExactly 'unsigned executable fixture'
            { Expand-VerifiedPowerShellArchive -Asset $asset -ArchivePath $archivePath -DestinationPath $runtimeRoot } | Should -Throw '*already exists*'
            { Assert-PowerShellExecutableSignature -Path $executablePath -Platform windows } | Should -Throw '*Authenticode*'

            $signature = Assert-PowerShellExecutableSignature -Path (Join-Path $PSHOME 'pwsh.exe') -Platform windows
            $signature.status | Should -BeExactly 'Valid'
            $signature.signerSubject | Should -Match '^CN=Microsoft Corporation(,|$)'
            $signature.signerThumbprint | Should -Match '^[0-9A-F]{40}$'

            $missingRoot = Join-Path $TestDrive 'windows-missing-staging'
            New-Item -ItemType Directory -Path $missingRoot | Out-Null
            [IO.File]::WriteAllText((Join-Path $missingRoot 'pwsh'), 'wrong executable name', [Text.UTF8Encoding]::new($false))
            $missingArchive = Join-Path $TestDrive 'windows-missing.zip'
            Compress-Archive -Path (Join-Path $missingRoot '*') -DestinationPath $missingArchive
            $missingAsset = New-HostPowerShellArchiveAsset -ArchivePath $missingArchive
            $missingRuntime = Join-Path $TestDrive 'windows-missing-runtime'
            { Expand-VerifiedPowerShellArchive -Asset $missingAsset -ArchivePath $missingArchive -DestinationPath $missingRuntime } |
                Should -Throw '*did not contain pwsh.exe*'
        }
    }

    # Register only on the native host: Linux and macOS archives are tar.gz files expanded by the host tar.
    if (-not $IsWindows) {
        # Scenario: A verified Linux or macOS archive is expanded by tar.
        # Purpose: Retain the archive execute mode, restore a missing owner execute bit, and skip Authenticode on Unix.
        It 'UnitT111_ExpandsTheUnixTarGzAndRetainsTheExecutableMode' -ForEach @(
            @{ Case = 'executable'; Mode = 'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute' }
            @{ Case = 'non-executable'; Mode = 'UserRead, UserWrite, GroupRead, OtherRead' }
        ) {
            $archivePath = Join-Path $TestDrive "unix-runtime-$Case.tar.gz"
            New-TestTarGzArchive -Path $archivePath -Entries @(
                @{ Name = 'pwsh'; Mode = $Mode; Content = "#!/bin/sh`necho fixture`n" }
                @{ Name = 'Modules/README.txt'; Mode = 'UserRead, UserWrite, GroupRead, OtherRead'; Content = 'module fixture' }
            )
            $asset = New-HostPowerShellArchiveAsset -ArchivePath $archivePath
            $asset.executableName | Should -BeExactly 'pwsh'
            $asset.name | Should -Match '^powershell-7\.6\.6-(linux|osx)-(x64|arm64)\.tar\.gz$'

            $runtimeRoot = Join-Path $TestDrive "unix-runtime-$Case"
            $executablePath = Expand-VerifiedPowerShellArchive -Asset $asset -ArchivePath $archivePath -DestinationPath $runtimeRoot
            $executablePath | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $runtimeRoot 'pwsh')))
            [IO.File]::ReadAllText($executablePath) | Should -BeExactly "#!/bin/sh`necho fixture`n"
            ([IO.File]::GetUnixFileMode($executablePath) -band [IO.UnixFileMode]::UserExecute) | Should -Be ([IO.UnixFileMode]::UserExecute)
            if ($Case -ceq 'executable') {
                ([IO.File]::GetUnixFileMode($executablePath) -band [IO.UnixFileMode]::OtherExecute) | Should -Be ([IO.UnixFileMode]::OtherExecute)
            }
            Test-Path -LiteralPath (Join-Path $runtimeRoot 'Modules/README.txt') -PathType Leaf | Should -BeTrue

            $signature = Assert-PowerShellExecutableSignature -Path $executablePath
            $signature.status | Should -BeNullOrEmpty
            $signature.signerSubject | Should -BeNullOrEmpty
        }

        # Scenario: A Unix archive contains a traversal member or lacks pwsh at its root.
        # Purpose: Reject archive members outside the run-owned runtime directory before extraction and require the platform executable name.
        It 'UnitT112_RejectsUnsafeOrIncompleteUnixArchives' {
            $traversalArchive = Join-Path $TestDrive 'unix-traversal.tar.gz'
            New-TestTarGzArchive -Path $traversalArchive -Entries @(
                @{ Name = 'pwsh'; Mode = 'UserRead, UserWrite, UserExecute'; Content = 'fixture' }
                @{ Name = '../escaped.txt'; Mode = 'UserRead, UserWrite'; Content = 'escaped' }
            )
            $traversalAsset = New-HostPowerShellArchiveAsset -ArchivePath $traversalArchive
            $traversalRuntime = Join-Path $TestDrive 'unix-traversal-runtime'
            { Expand-VerifiedPowerShellArchive -Asset $traversalAsset -ArchivePath $traversalArchive -DestinationPath $traversalRuntime } |
                Should -Throw '*escapes the run-owned runtime directory*'
            Test-Path -LiteralPath $traversalRuntime | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $TestDrive 'escaped.txt') | Should -BeFalse

            $windowsNameArchive = Join-Path $TestDrive 'unix-windows-name.tar.gz'
            New-TestTarGzArchive -Path $windowsNameArchive -Entries @(
                @{ Name = 'pwsh.exe'; Mode = 'UserRead, UserWrite, UserExecute'; Content = 'fixture' }
            )
            $windowsNameAsset = New-HostPowerShellArchiveAsset -ArchivePath $windowsNameArchive
            $windowsNameRuntime = Join-Path $TestDrive 'unix-windows-name-runtime'
            { Expand-VerifiedPowerShellArchive -Asset $windowsNameAsset -ArchivePath $windowsNameArchive -DestinationPath $windowsNameRuntime } |
                Should -Throw '*did not contain pwsh at its root*'
        }
    }

    # Scenario: An archive selected for another operating system reaches the expansion step.
    # Purpose: Refuse to install a runtime whose platform differs from the host.
    It 'UnitT113_RejectsExpandingAnotherPlatformArchive' {
        $otherPlatform = if ($IsWindows) { 'linux' } else { 'windows' }
        $otherName = Get-PowerShellReleaseAssetName -Version '7.6.6' -Platform $otherPlatform -Architecture 'x64'
        $asset = Get-VerifiedPowerShellReleaseAsset -Release (New-LatestPowerShellReleaseFixture -AssetName $otherName) -Platform $otherPlatform -Architecture 'x64'
        $archivePath = Join-Path $TestDrive 'other-platform-archive'
        [IO.File]::WriteAllText($archivePath, 'other platform', [Text.UTF8Encoding]::new($false))
        $otherRuntime = Join-Path $TestDrive 'other-platform-runtime'
        { Expand-VerifiedPowerShellArchive -Asset $asset -ArchivePath $archivePath -DestinationPath $otherRuntime } |
            Should -Throw '*cannot be installed on a*'
        Test-Path -LiteralPath $otherRuntime | Should -BeFalse
    }
}
