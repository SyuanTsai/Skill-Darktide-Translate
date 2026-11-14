# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:repositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:verifiedPowerShellExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    Import-Module -Name (Join-Path $script:repositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force
    $script:closureLockPath = Join-Path $script:repositoryRoot 'config/pester-6.2.0-closure.lock.json'
    $script:closureLock = Read-CorePesterClosureLock -LiteralPath $script:closureLockPath
    $script:loadedPester = @(Get-Module -Name Pester | Where-Object { $_.Version -eq [version]'6.2.0' }) | Select-Object -First 1
    if ($null -eq $script:loadedPester) { throw 'Integrity tests require the explicitly prepared Pester 6.2.0 test host.' }

    function Assert-TestThrowsLike {
        param([scriptblock] $ScriptBlock, [string] $Pattern)
        $caught = $null
        try { & $ScriptBlock } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        ([string]$caught.Exception.Message) | Should -BeLike $Pattern
    }

    function New-IntegrityPackageFixture {
        param([Parameter(Mandatory)][string] $Path, [string] $Variant = 'valid')

        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                $unixRegularFileAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]::Parse('81A40000', [Globalization.NumberStyles]::HexNumber)), 0) # S_IFREG | 0644
                $unixSymbolicLinkAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]::Parse('A1FF0000', [Globalization.NumberStyles]::HexNumber)), 0) # S_IFLNK | 0777
                foreach ($payload in $script:closureLock.Value.modulePayload) {
                    $entryName = [string]$payload.path
                    if ($Variant -eq 'case-mismatch' -and $entryName -ceq 'Pester.psd1') { $entryName = 'pester.psd1' }
                    $entry = $zip.CreateEntry($entryName)
                    $entry.ExternalAttributes = if ($Variant -eq 'unix-symlink' -and [string]$payload.path -ceq 'Pester.psm1') {
                        $unixSymbolicLinkAttributes
                    }
                    else { $unixRegularFileAttributes }
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
                    $entry.ExternalAttributes = $unixRegularFileAttributes
                    $target = $entry.Open()
                    try { $target.WriteByte(0x20) } finally { $target.Dispose() }
                }
                $nuspec = '<package><metadata><id>Pester</id><version>6.2.0</version></metadata></package>'
                $entry = $zip.CreateEntry('Pester.nuspec')
                $entry.ExternalAttributes = $unixRegularFileAttributes
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

    function New-TestDirectoryReparsePoint {
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Target)

        if ($IsWindows) {
            New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
        }
        else {
            New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
        }
    }
}

Describe 'Legacy Core process bootstrap transport' {
    # Scenario: Either obsolete bootstrap transport variable is present in the Core child environment.
    # Purpose: Fail closed instead of consuming a candidate-root signal that the current authority never creates.
    It 'UnitT10_rejects_present_legacy_bootstrap_variable_<VariableName>' -ForEach @(
        @{ VariableName = 'STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH' },
        @{ VariableName = 'STANDARD_VALIDATION_BOOTSTRAP_COMMAND' }
    ) {
        $names = @('STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH', 'STANDARD_VALIDATION_BOOTSTRAP_COMMAND')
        $previous = @{}
        try {
            foreach ($name in $names) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            [Environment]::SetEnvironmentVariable($VariableName, 'unexpected-legacy-transport', 'Process')
            Assert-TestThrowsLike { Assert-NoLegacyCorePesterBootstrapEnvironment } "*unexpected legacy bootstrap transport variable '$VariableName'*"
        }
        finally {
            foreach ($name in $names) {
                if ($null -eq $previous[$name]) {
                    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
                }
                else {
                    Set-Item -LiteralPath "Env:$name" -Value $previous[$name]
                }
            }
        }
    }

    # Scenario: The current owned-process Core launch contains no legacy bootstrap transport variables.
    # Purpose: Accept the new authority contract without requiring or deleting a one-shot signal file.
    It 'UnitT20_accepts_the_current_owned_process_environment_contract' {
        $names = @('STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH', 'STANDARD_VALIDATION_BOOTSTRAP_COMMAND')
        $previous = @{}
        try {
            foreach ($name in $names) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
            { Assert-NoLegacyCorePesterBootstrapEnvironment } | Should -Not -Throw
        }
        finally {
            foreach ($name in $names) {
                if ($null -eq $previous[$name]) {
                    Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
                }
                else {
                    Set-Item -LiteralPath "Env:$name" -Value $previous[$name]
                }
            }
        }

        $wrapper = Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'scripts/Invoke-CorePester.ps1') -Raw
        $wrapper | Should -Match 'Assert-NoLegacyCorePesterBootstrapEnvironment'
        $wrapper | Should -Not -Match 'Remove-CorePesterConsumedBootstrapSignal|STANDARD_VALIDATION_BOOTSTRAP_(?:RELEASE_PATH|COMMAND)'
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
        Assert-TestThrowsLike { Read-CorePesterClosureLock -LiteralPath $duplicatePath } '*duplicate*'

        $object = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $object.modulePayload[1].path = '../escape.ps1'
        $unsafePath = Join-Path $TestDrive 'unsafe-path.json'
        $object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $unsafePath -Encoding utf8
        Assert-TestThrowsLike { Read-CorePesterClosureLock -LiteralPath $unsafePath } '*unsafe relative path*'

        $object = Get-Content -LiteralPath $script:closureLockPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $object.modulePayload[1].path = $object.modulePayload[0].path
        $duplicateEntryPath = Join-Path $TestDrive 'duplicate-entry.json'
        $object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $duplicateEntryPath -Encoding utf8
        Assert-TestThrowsLike { Read-CorePesterClosureLock -LiteralPath $duplicateEntryPath } '*duplicate*'
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
        New-TestDirectoryReparsePoint -Path $link -Target $outsideRoot
        try {
            (Test-CorePesterClosure -ModuleRoot $moduleRoot -Lock $fixtureLock).Errors | Should -Contain "Pester closure contains a reparse point: $link"
            Test-Path -LiteralPath $outsideFile | Should -BeTrue
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    # Scenario: A destination escapes its registered runtime boundary or traverses a redirected ancestor.
    # Purpose: Fail closed on escaped paths and detect directory links without altering their target.
    It 'UnitT25_rejects_escaped_paths_and_reparse_point_ancestors' {
        $boundary = Join-Path $TestDrive 'runtime-boundary'
        $outside = Join-Path $TestDrive 'outside-boundary'
        [void](New-Item -ItemType Directory -Path $boundary)
        [void](New-Item -ItemType Directory -Path $outside)
        $outsideProbe = Join-Path $outside 'survives.txt'
        [IO.File]::WriteAllText($outsideProbe, 'outside target', [Text.UTF8Encoding]::new($false))

        (Test-CorePesterPathBoundary -Path (Join-Path $boundary 'Modules/Pester/6.2.0') -Boundary $boundary).IsValid | Should -BeTrue
        (Test-CorePesterPathBoundary -Path $outside -Boundary $boundary).Errors | Should -Contain 'Path escaped its registered boundary.'

        $link = Join-Path $boundary 'redirected'
        New-TestDirectoryReparsePoint -Path $link -Target $outside
        try {
            $redirected = Test-CorePesterPathBoundary -Path (Join-Path $link 'Modules/Pester/6.2.0') -Boundary $boundary
            $redirected.IsValid | Should -BeFalse
            @($redirected.Errors | Where-Object { $_ -like 'Path ancestry contains a reparse point:*' }).Count | Should -BeGreaterThan 0

            $linkedBoundary = Test-CorePesterPathBoundary -Path (Join-Path $link 'Modules') -Boundary $link
            $linkedBoundary.IsValid | Should -BeFalse
            @($linkedBoundary.Errors | Where-Object { $_ -like 'Path ancestry contains a reparse point:*' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $outsideProbe | Should -BeTrue
            [IO.File]::ReadAllText($outsideProbe) | Should -Be 'outside target'
        }
        finally { Remove-Item -LiteralPath $link -Force }
    }

    # Scenario: a trusted run root lives below a platform-owned symlink such as macOS /tmp.
    # Purpose: inspect the registered boundary itself and its descendants without rejecting unrelated system ancestors.
    It 'UnitT26_does_not_walk_above_the_registered_trusted_boundary' {
        $boundary = Join-Path $TestDrive 'trusted-boundary'
        [void](New-Item -ItemType Directory -Path (Join-Path $boundary 'child') -Force)
        (Test-CorePesterPathBoundary -Path (Join-Path $boundary 'child') -Boundary $boundary).IsValid | Should -BeTrue
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

    # Scenario: The child imports one locked Pester manifest whose root module and runtime root match the expected identity.
    # Purpose: Reject a same-version module redirected through another entry point or runtime directory.
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

    # Scenario: The exact payload carries signed Unix regular-file mode bits, with a paired symbolic-link variant.
    # Purpose: Accept the complete regular-file hash inventory and reject symlink, extra, duplicate, unsafe, or byte-mismatched entries.
    It 'UnitT50_accepts_exact_package_inventory_and_rejects_unclassified_archive_entries' {
        $validPath = Join-Path $TestDrive 'pester-valid.nupkg'
        New-IntegrityPackageFixture -Path $validPath
        (Test-CorePesterPackageArchive -ArchivePath $validPath -Lock $script:closureLock.Value).IsValid | Should -BeTrue

        foreach ($variant in @('extra', 'duplicate', 'unsafe', 'hash-mismatch', 'case-mismatch', 'unix-symlink')) {
            $badPath = Join-Path $TestDrive "pester-$variant.nupkg"
            New-IntegrityPackageFixture -Path $badPath -Variant $variant
            $result = Test-CorePesterPackageArchive -ArchivePath $badPath -Lock $script:closureLock.Value
            $result.IsValid | Should -BeFalse -Because "variant $variant must fail closed"
            $result.Errors.Count | Should -BeGreaterThan 0
            if ($variant -eq 'unix-symlink') {
                $result.Errors | Should -Contain 'Pester package archive contains a symbolic link: Pester.psm1'
            }
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
