# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force
    $script:closureLockPath = Join-Path $script:repositoryRoot 'config/pester-6.2.0-closure.lock.json'
    $script:closureLock = Read-CorePesterClosureLock -LiteralPath $script:closureLockPath
    $script:loadedPester = @(Get-Module -Name Pester | Where-Object { $_.Version -eq [version]'6.2.0' }) | Select-Object -First 1
    if ($null -eq $script:loadedPester) { throw 'Integrity tests require the explicitly prepared Pester 6.2.0 test host.' }

    function New-IntegrityPackageFixture {
        param([Parameter(Mandatory)][string] $Path, [string] $Variant = 'valid')

        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($payload in $script:closureLock.Value.modulePayload) {
                    $entryName = [string]$payload.path
                    if ($Variant -eq 'case-mismatch' -and $entryName -ceq 'Pester.psd1') { $entryName = 'pester.psd1' }
                    $entry = $zip.CreateEntry($entryName)
                    $target = $entry.Open()
                    try {
                        if ($Variant -eq 'hash-mismatch' -and [string]$payload.path -ceq 'Pester.psm1') {
                            $badBytes = [Text.Encoding]::UTF8.GetBytes('unexpected module bytes')
                            $target.Write($badBytes, 0, $badBytes.Length)
                        }
                        else {
                            $sourcePath = Join-Path $script:loadedPester.ModuleBase ([string]$payload.path)
                            $bytes = [IO.File]::ReadAllBytes($sourcePath)
                            $target.Write($bytes, 0, $bytes.Length)
                        }
                    }
                    finally { $target.Dispose() }
                }
                foreach ($name in @('_rels/.rels', '[Content_Types].xml', 'package/services/metadata/core-properties/nuget.psmdcp')) {
                    $entry = $zip.CreateEntry($name)
                    $target = $entry.Open()
                    try { $target.WriteByte(0x20) } finally { $target.Dispose() }
                }
                $nuspec = '<package><metadata><id>Pester</id><version>6.2.0</version></metadata></package>'
                $entry = $zip.CreateEntry('Pester.nuspec')
                $target = $entry.Open()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes($nuspec)
                    $target.Write($bytes, 0, $bytes.Length)
                }
                finally { $target.Dispose() }
                if ($Variant -eq 'extra') { [void]$zip.CreateEntry('extra.ps1') }
                if ($Variant -eq 'duplicate') { [void]$zip.CreateEntry('_rels/.rels') }
                if ($Variant -eq 'unsafe') { [void]$zip.CreateEntry('../outside.ps1') }
            }
            finally { $zip.Dispose() }
        }
        finally { $stream.Dispose() }
    }
}

Describe 'Consumed Core process bootstrap signal' {
    # Scenario: The owned bootstrap has released the child before its snapshot is bound.
    # Purpose: Remove only the exact consumed transport file while hashing every source byte.
    It 'UnitT10_restores_the_full_source_snapshot_and_preserves_other_signal_like_files' {
        $root = Join-Path $TestDrive 'source-candidate'
        [void](New-Item -ItemType Directory -Path $root)
        $source = Join-Path $root 'b-11111111111111111111111111111111.sig'
        [IO.File]::WriteAllText($source, 'tracked source bytes')
        $before = Get-CorePesterTreeSnapshot -Root $root
        $signal = Join-Path $root 'b-22222222222222222222222222222222.sig'
        [IO.File]::WriteAllText($signal, ('release' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        (Get-CorePesterTreeSnapshot -Root $root).Sha256 | Should -Not -Be $before.Sha256
        Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $root -ReleasePath $signal -BootstrapCommand 'C:/verified/pwsh.exe' -VerifiedPowerShellExecutable 'C:/verified/pwsh.exe'
        Test-Path -LiteralPath $signal | Should -BeFalse
        (Get-CorePesterTreeSnapshot -Root $root).Sha256 | Should -Be $before.Sha256
        [IO.File]::ReadAllText($source) | Should -Be 'tracked source bytes'
    }

    # Scenario: Bootstrap metadata selects a foreign path, name, payload or command.
    # Purpose: Fail closed without deleting any file rather than excluding it from integrity checks.
    It 'UnitT20_rejects_invalid_bootstrap_metadata_<Variant>' -ForEach @(
        @{ Variant = 'outside' }, @{ Variant = 'name' }, @{ Variant = 'bytes' },
        @{ Variant = 'command' }, @{ Variant = 'missing' }, @{ Variant = 'directory' }
    ) {
        $root = Join-Path $TestDrive ("invalid-$Variant-candidate")
        [void](New-Item -ItemType Directory -Path $root)
        $signal = Join-Path $root 'b-22222222222222222222222222222222.sig'
        if ($Variant -eq 'outside') { $signal = Join-Path $TestDrive 'b-22222222222222222222222222222222.sig' }
        if ($Variant -eq 'name') { $signal = Join-Path $root 'source.ps1' }
        $bytes = if ($Variant -eq 'bytes') { 'wrong' } else { 'release' + [Environment]::NewLine }
        if ($Variant -eq 'directory') { [void](New-Item -ItemType Directory -Path $signal) }
        elseif ($Variant -ne 'missing') { [IO.File]::WriteAllText($signal, $bytes, [Text.UTF8Encoding]::new($false)) }
        $command = if ($Variant -eq 'command') { 'C:/unverified/pwsh.exe' } else { 'C:/verified/pwsh.exe' }
        { Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $root -ReleasePath $signal -BootstrapCommand $command -VerifiedPowerShellExecutable 'C:/verified/pwsh.exe' } | Should -Throw '*Core Pester bootstrap*'
        if ($Variant -ne 'missing') { Test-Path -LiteralPath $signal | Should -BeTrue }
    }

    # Scenario: A candidate directory is redirected through a junction.
    # Purpose: Prevent consumed-signal cleanup from crossing a reparse ancestor.
    It 'UnitT30_rejects_reparse_ancestry_without_deleting_the_signal' {
        $outside = Join-Path $TestDrive 'outside'
        [void](New-Item -ItemType Directory -Path $outside)
        $link = Join-Path $TestDrive 'reparse-candidate'
        New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop | Out-Null
        $signal = Join-Path $link 'b-22222222222222222222222222222222.sig'
        [IO.File]::WriteAllText($signal, ('release' + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        try {
            { Remove-CorePesterConsumedBootstrapSignal -CandidateRoot $link -ReleasePath $signal -BootstrapCommand 'C:/verified/pwsh.exe' -VerifiedPowerShellExecutable 'C:/verified/pwsh.exe' } | Should -Throw '*Core Pester bootstrap*'
            Test-Path -LiteralPath $signal | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    # Scenario: The canonical wrapper binds its first full snapshot after trusted identity checks.
    # Purpose: Keep transport cleanup before both before/after source integrity snapshots.
    It 'UnitT40_cleans_consumed_signal_after_authority_verification_before_first_snapshot' {
        $wrapper = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1') -Raw
        $authority = $wrapper.IndexOf('$verifiedAuthoritySnapshotRoot = Get-VerifiedCoreAuthoritySnapshotPath', [StringComparison]::Ordinal)
        $cleanup = $wrapper.IndexOf('Remove-CorePesterConsumedBootstrapSignal -CandidateRoot', [StringComparison]::Ordinal)
        $snapshot = $wrapper.IndexOf('$candidateSnapshotBefore = Get-CorePesterTreeSnapshot', [StringComparison]::Ordinal)
        ($authority -ge 0 -and $cleanup -gt $authority -and $snapshot -gt $cleanup) | Should -BeTrue
    }
}

Describe 'Verified Pester 6.2.0 module closure' {
    # Scenario: The trusted package lock is consumed before any module import.
    # Purpose: Reject malformed, ambiguous, unsafe, or unpinned closure declarations.
    It 'UnitT10_rejects_malformed_or_ambiguous_lock_documents' {
        $lock = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8
        $duplicateProperty = $lock -replace '"schemaVersion": 1,', '"schemaVersion": 1, "schemaVersion": 1,'
        $duplicatePath = Join-Path $TestDrive 'duplicate-property.json'
        [IO.File]::WriteAllText($duplicatePath, $duplicateProperty, [Text.UTF8Encoding]::new($false))
        { Read-CorePesterClosureLock -LiteralPath $duplicatePath } | Should -Throw '*duplicate*'

        $object = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $object.modulePayload[1].path = '../escape.ps1'
        $unsafePath = Join-Path $TestDrive 'unsafe-path.json'
        $object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $unsafePath -Encoding utf8
        { Read-CorePesterClosureLock -LiteralPath $unsafePath } | Should -Throw '*unsafe relative path*'

        $object = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $object.modulePayload[1].path = $object.modulePayload[0].path
        $duplicateEntryPath = Join-Path $TestDrive 'duplicate-entry.json'
        $object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $duplicateEntryPath -Encoding utf8
        { Read-CorePesterClosureLock -LiteralPath $duplicateEntryPath } | Should -Throw '*duplicate*'
    }

    # Scenario: An explicit module root is checked as a complete relative path and hash inventory.
    # Purpose: Detect missing, extra, altered, or reparse-backed payload before import and after execution.
    It 'UnitT20_rejects_missing_extra_hash_mismatch_and_reparse_payloads' {
        $moduleRoot = Join-Path $TestDrive 'module-closure'
        [void](New-Item -ItemType Directory -Path $moduleRoot)
        $content = @{
            'Pester.psd1' = '@{ ModuleVersion = ''6.2.0'' }'
            'Pester.psm1' = 'function Invoke-Pester { }'
        }
        $payload = @(
            foreach ($path in $content.Keys) {
                $fullPath = Join-Path $moduleRoot $path
                [IO.File]::WriteAllText($fullPath, $content[$path], [Text.UTF8Encoding]::new($false))
                [pscustomobject]@{ path = $path; sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
        )
        $fixtureLock = [pscustomobject]@{ modulePayload = $payload }
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).IsValid | Should -BeTrue

        Remove-Item -LiteralPath (Join-Path $moduleRoot 'Pester.psm1') -Force
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain 'Pester closure payload is missing: Pester.psm1'
        [IO.File]::WriteAllText((Join-Path $moduleRoot 'Pester.psm1'), 'changed bytes', [Text.UTF8Encoding]::new($false))
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain 'Pester closure hash mismatch: Pester.psm1'
        [IO.File]::WriteAllText((Join-Path $moduleRoot 'unexpected.ps1'), 'not pinned', [Text.UTF8Encoding]::new($false))
        (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain 'Pester closure contains unpinned file: unexpected.ps1'
        Remove-Item -LiteralPath (Join-Path $moduleRoot 'unexpected.ps1') -Force

        $outsideRoot = Join-Path $TestDrive 'outside-module'
        [void](New-Item -ItemType Directory -Path $outsideRoot)
        $outsideFile = Join-Path $outsideRoot 'payload.ps1'
        [IO.File]::WriteAllText($outsideFile, 'outside', [Text.UTF8Encoding]::new($false))
        $link = Join-Path $moduleRoot 'linked'
        New-Item -ItemType Junction -Path $link -Target $outsideRoot -ErrorAction Stop | Out-Null
        try {
            (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain "Pester closure contains a reparse point: $link"
        }
        finally { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    }

    It 'UnitT25_rejects_escaped_paths_and_reparse_point_ancestors' {
        $boundary = Join-Path $TestDrive 'runtime-boundary'
        $outside = Join-Path $TestDrive 'outside-boundary'
        [void](New-Item -ItemType Directory -Path $boundary)
        [void](New-Item -ItemType Directory -Path $outside)

        (Test-CorePesterPathBoundary -Path (Join-Path $boundary 'Modules/Pester/6.2.0') -Boundary $boundary).IsValid | Should -BeTrue
        (Test-CorePesterPathBoundary -Path $outside -Boundary $boundary).Errors | Should -Contain 'Path escaped its registered boundary.'

        $link = Join-Path $boundary 'redirected'
        New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop | Out-Null
        try {
            $redirected = Test-CorePesterPathBoundary -Path (Join-Path $link 'Modules/Pester/6.2.0') -Boundary $boundary
            $redirected.IsValid | Should -BeFalse
            @($redirected.Errors | Where-Object { $_ -like 'Path ancestry contains a reparse point:*' }).Count | Should -BeGreaterThan 0

            $linkedBoundary = Test-CorePesterPathBoundary -Path (Join-Path $link 'Modules') -Boundary $link
            $linkedBoundary.IsValid | Should -BeFalse
            @($linkedBoundary.Errors | Where-Object { $_ -like 'Path ancestry contains a reparse point:*' }).Count | Should -BeGreaterThan 0
        }
        finally { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    }

    # Scenario: The runtime exposes the exact locked manifest alongside an injected ambient copy.
    # Purpose: Ensure same-version module search results cannot redirect child imports.
    It 'UnitT30_accepts_only_the_single_manifest_under_the_verified_runtime' {
        $manifest = Join-Path $TestDrive 'runtime/Modules/Pester/6.2.0/Pester.psd1'
        $same = @([pscustomobject]@{ Version = [version]'6.2.0'; Path = $manifest })
        (Test-CorePesterModuleCandidates -ExpectedManifestPath $manifest -Candidates $same).IsValid | Should -BeTrue
        $injected = @($same) + @([pscustomobject]@{ Version = [version]'6.2.0'; Path = (Join-Path $TestDrive 'ambient/Pester.psd1') })
        $rejected = Test-CorePesterModuleCandidates -ExpectedManifestPath $manifest -Candidates $injected
        $rejected.IsValid | Should -BeFalse
        $rejected.Errors | Should -Contain "An ambient Pester 6.2.0 module candidate exists outside the verified runtime: $(Join-Path $TestDrive 'ambient/Pester.psd1')"
        (Test-CorePesterModuleCandidates -ExpectedManifestPath $manifest -Candidates @()).IsValid | Should -BeFalse
    }

    It 'UnitT35_binds_imported_module_to_manifest_entry_point_and_runtime_root' {
        $manifest = Join-Path $script:loadedPester.ModuleBase ([string]$script:closureLock.Value.runtime.manifestRelativePath)
        $expectedPath = Get-CorePesterExpectedLoadedModulePath -ManifestPath $manifest -ModuleRoot $script:loadedPester.ModuleBase -Lock $script:closureLock.Value
        $expectedPath | Should -Be ([IO.Path]::GetFullPath([string]$script:loadedPester.Path))

        $accepted = Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $expectedPath -ExpectedModuleBase $script:loadedPester.ModuleBase
        $accepted.IsValid | Should -BeTrue
        (Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $manifest -ExpectedModuleBase $script:loadedPester.ModuleBase).Errors | Should -Contain 'Loaded Pester module path differs from the manifest RootModule entry point.'
        (Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $expectedPath -ExpectedModuleBase (Join-Path $TestDrive 'wrong-runtime')).Errors | Should -Contain 'Loaded Pester module base differs from the verified runtime module root.'
        (Test-CorePesterLoadedModuleIdentity -Modules @($script:loadedPester, $script:loadedPester) -ExpectedVersion '6.2.0' -ExpectedPath $expectedPath -ExpectedModuleBase $script:loadedPester.ModuleBase).Errors | Should -Contain 'Exactly one Pester module must be loaded in the Core child.'

        $fixtureRoot = Join-Path $TestDrive 'manifest-root-module'
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        $fixtureManifest = Join-Path $fixtureRoot 'Pester.psd1'
        [IO.File]::WriteAllText($fixtureManifest, "@{ RootModule = '../outside.psm1' }`n", [Text.UTF8Encoding]::new($false))
        $fixtureLock = [pscustomobject]@{
            runtime = [pscustomobject]@{ manifestRelativePath = 'Pester.psd1' }
            modulePayload = @([pscustomobject]@{ path = 'outside.psm1' })
        }
        { Get-CorePesterExpectedLoadedModulePath -ManifestPath $fixtureManifest -ModuleRoot $fixtureRoot -Lock $fixtureLock } | Should -Throw
    }

    # Scenario: A one-invocation Core run records every full case identity in exactly one shard.
    # Purpose: Prevent counts-only acceptance, identity truncation, duplicate cases, and shard omissions.
    It 'UnitT40_requires_a_complete_duplicate_free_core_full_case_union' {
        $first = Get-CorePesterCaseIdentity -RelativeSourceFile 'Core.Tests.ps1' -StartOffset 11 -ExpandedPath 'Same name'
        $sameNameOtherBlock = Get-CorePesterCaseIdentity -RelativeSourceFile 'Core.Tests.ps1' -StartOffset 80 -ExpandedPath 'Same name'
        $sameNameOtherFile = Get-CorePesterCaseIdentity -RelativeSourceFile 'Other.Tests.ps1' -StartOffset 11 -ExpandedPath 'Same name'
        $longIdentity = Get-CorePesterCaseIdentity -RelativeSourceFile 'Core.Tests.ps1' -StartOffset 220 -ExpandedPath ('Long ' + ('case' * 100))
        @($first, $sameNameOtherBlock, $sameNameOtherFile, $longIdentity | Select-Object -Unique).Count | Should -Be 4
        $shard = [pscustomobject]@{ id = 'core-full'; caseIdentities = @($first, $sameNameOtherBlock, $sameNameOtherFile, $longIdentity) }
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first, $sameNameOtherBlock, $sameNameOtherFile, $longIdentity) -Shards @($shard)).IsValid | Should -BeTrue

        (Test-CorePesterShardUnion -DiscoveredIdentities @($first, $sameNameOtherBlock) -Shards @([pscustomobject]@{ id = 'core-full'; caseIdentities = @($first) })).IsValid | Should -BeFalse
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first) -Shards @([pscustomobject]@{ id = 'core-full'; caseIdentities = @($first, $first) })).IsValid | Should -BeFalse
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first) -Shards @([pscustomobject]@{ id = 'unknown'; caseIdentities = @($first) })).IsValid | Should -BeFalse
        (Test-CorePesterShardUnion -DiscoveredIdentities @($first) -Shards @()).IsValid | Should -BeFalse
    }

    # Scenario: Case result partitions preserve full identity and completion semantics.
    # Purpose: Reject the discovered-but-not-executed escape while counting expanded Pester names correctly.
    It 'UnitT45_rejects_missing_execution_and_pairs_parameterized_progress_lines' {
        $discovered = @(
            [pscustomobject]@{ identity = 'case-alpha'; sourceFile = 'fixture.Tests.ps1'; sourceStartLine = 4; expandedPath = 'Fixture.Case alpha'; result = 'Passed' }
            [pscustomobject]@{ identity = 'case-beta'; sourceFile = 'fixture.Tests.ps1'; sourceStartLine = 9; expandedPath = 'Fixture.Case beta'; result = 'Passed' }
        )
        $complete = Test-CorePesterCaseIdentityPartition -DiscoveryCases $discovered -ExecutionCases $discovered
        $complete.IsValid | Should -BeTrue
        $missing = Test-CorePesterCaseIdentityPartition -DiscoveryCases $discovered -ExecutionCases @($discovered[0])
        $missing.IsValid | Should -BeFalse
        $missing.Errors | Should -Contain 'Pester discovered a case with no execution status: fixture.Tests.ps1:9 Fixture.Case beta'
        $duplicate = Test-CorePesterCaseIdentityPartition -DiscoveryCases @($discovered[0], $discovered[0]) -ExecutionCases @($discovered[0])
        $duplicate.Errors | Should -Contain 'Pester discovered duplicate or ambiguous case identity: fixture.Tests.ps1:4 Fixture.Case alpha'

        $start = ConvertFrom-CorePesterProgressLine -Line '  [|] Case <Value>...' -ActiveCaseStarts 0
        $start.IsRecognized | Should -BeTrue
        $start.Phase | Should -Be 'case-start'
        $start.ActiveCaseStarts | Should -Be 1
        $start.CompletedDelta | Should -Be 0
        $end = ConvertFrom-CorePesterProgressLine -Line '  [+] Case alpha' -ActiveCaseStarts $start.ActiveCaseStarts
        $end.Phase | Should -Be 'case-end'
        $end.ActiveCaseStarts | Should -Be 0
        $end.CompletedDelta | Should -Be 1
        $unpaired = ConvertFrom-CorePesterProgressLine -Line '  [+] unrelated' -ActiveCaseStarts 0
        $unpaired.CompletedDelta | Should -Be 0
        (ConvertFrom-CorePesterProgressLine -Line 'unrelated diagnostic' -ActiveCaseStarts 0).IsRecognized | Should -BeFalse
    }

    # Scenario: Official package entries are classified and bound to the exact module payload lock.
    # Purpose: Reject extra, duplicate, unsafe, or byte-mismatched archive contents before runtime staging.
    It 'UnitT50_accepts_exact_package_inventory_and_rejects_unclassified_archive_entries' {
        $validPath = Join-Path $TestDrive 'pester-valid.nupkg'
        New-IntegrityPackageFixture -Path $validPath
        (Test-CorePesterPackageArchive -ArchivePath $validPath -Lock $script:closureLock.Value).IsValid | Should -BeTrue

        foreach ($variant in @('extra', 'duplicate', 'unsafe', 'hash-mismatch', 'case-mismatch')) {
            $badPath = Join-Path $TestDrive "pester-$variant.nupkg"
            New-IntegrityPackageFixture -Path $badPath -Variant $variant
            $result = Test-CorePesterPackageArchive -ArchivePath $badPath -Lock $script:closureLock.Value
            $result.IsValid | Should -BeFalse -Because "variant $variant must fail closed"
            $result.Errors.Count | Should -BeGreaterThan 0
        }
    }

    # Scenario: Normal Core wrapper is source-bound to the exact runtime and performs no acquisition.
    # Purpose: Keep setup separate from execution and prevent ambient-module fallback or runtime downloads.
    It 'UnitT60_keeps_download_and_install_commands_out_of_the_core_child' {
        $wrapper = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1') -Raw -Encoding utf8
        $wrapper | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|Install-PSResource|Install-Module|Save-Module|Save-PSResource'
        $wrapper | Should -Match 'Get-CorePesterRuntimeModuleRoot'
        $wrapper | Should -Match 'Test-CorePesterClosure'
        $wrapper | Should -Match 'Get-CorePesterExpectedLoadedModulePath'
        $wrapper | Should -Match 'Test-CorePesterLoadedModuleIdentity'
        $acceptanceGateOffset = $wrapper.IndexOf('if (-not $caseInventoryLedgerWritten', [StringComparison]::Ordinal)
        $successReportOffset = $wrapper.IndexOf('[Console]::Out.WriteLine((ConvertTo-Json -InputObject $summary -Compress))', [StringComparison]::Ordinal)
        ($acceptanceGateOffset -ge 0 -and $successReportOffset -gt $acceptanceGateOffset) | Should -BeTrue
        $setup = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Prepare-PesterRuntime.ps1') -Raw -Encoding utf8
        $setup | Should -Match 'https://www\.powershellgallery\.com/api/v2/package/Pester/6\.2\.0'
        $setup | Should -Match 'Invoke-WebRequest.*-PassThru'
        $setup | Should -Match 'observedFinalPackageUri'
        $setup | Should -Match 'Test-CorePesterPackageArchive'
        $setup | Should -Match 'Test-CorePesterPathBoundary'
        $setup | Should -Match 'Refusing unsafe recursive runtime cleanup'
        $setup | Should -Match 'Refusing unsafe recursive staging cleanup'
        $setup | Should -Not -Match 'Install-PSResource|Install-Module|CurrentUser'
    }
}
