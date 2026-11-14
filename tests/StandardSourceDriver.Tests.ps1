# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:DriverPath = Join-Path $script:RepositoryRoot 'scripts/StandardSourceDriver.psm1'
    $script:LegPath = Join-Path $script:RepositoryRoot 'scripts/StandardWorkflowLeg.psm1'
    $script:ValidatePath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
    $script:ChildPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceChild.ps1'
    $script:PowerShellPath = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $script:AuthorityRoot = [Environment]::GetEnvironmentVariable('DT_TEST_AUTHORITY_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($script:AuthorityRoot)) {
        $script:AuthorityRoot = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '../mainbase'))
    }
    $authorityManifest = Join-Path $script:AuthorityRoot 'scripts/platform-runtime.psd1'
    if (-not (Test-Path -LiteralPath $authorityManifest -PathType Leaf) -or (Get-FileHash -LiteralPath $authorityManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'd3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9') {
        $sourceRepository = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '../mainbase'))
        $authorityArchive = Join-Path $TestDrive 'authority-fbdc793.zip'
        $script:AuthorityRoot = Join-Path $TestDrive 'authority-fbdc793'
        & git -C $sourceRepository archive --format=zip --output=$authorityArchive fbdc793c1c439b15c6def97d53111f250d0ff4db
        if ($LASTEXITCODE -ne 0) { throw 'Could not materialize the offline authority fixture.' }
        Expand-Archive -LiteralPath $authorityArchive -DestinationPath $script:AuthorityRoot
    }
    # Unit fixtures inject the already hash-pinned vendored runtime into the test
    # host. Production entry points must bootstrap only from the reviewed
    # authority checkout and are covered by separate child-process tests.
    $script:PathSafetyTestModule = Import-Module -Name (Join-Path $script:RepositoryRoot 'skills/auto-update-darktide-mod/scripts/PathSafety.psm1') -Force -PassThru
    $script:PlatformRuntimeTestModule = & $script:PathSafetyTestModule { $script:VendoredPlatformRuntimeModule }
    Import-Module -ModuleInfo $script:PlatformRuntimeTestModule -Force
    $script:DriverModule = Import-Module -Name $script:DriverPath -Force -PassThru
    & $script:DriverModule {
        param($RuntimeModule)
        Import-Module -ModuleInfo $RuntimeModule -Force
        $script:DarktideAuthorityPlatformRuntimeModule = $RuntimeModule
    } $script:PlatformRuntimeTestModule
    Import-Module -Name $script:LegPath -Force

    function Assert-TestThrowsLike {
        param([scriptblock] $ScriptBlock, [string] $Pattern)
        $caught = $null
        try { & $ScriptBlock } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        ([string]$caught.Exception.Message) | Should -BeLike $Pattern
    }

    function New-TestAuthorityObject {
        $pin = Get-DarktideSourceAuthorityPin
        return [pscustomobject][ordered]@{
            repository = [string]$pin.repository
            commit = [string]$pin.commit
            archiveUrl = [string]$pin.archiveUrl
            archiveSha256 = [string]$pin.archiveSha256
            files = @($pin.files.GetEnumerator() | ForEach-Object { [pscustomobject][ordered]@{ path = [string]$_.Key; sha256 = [string]$_.Value } })
        }
    }

    function New-TestGitRepository {
        param([Parameter(Mandatory)][string] $Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        & $script:GitPath -C $Root init --quiet
        foreach ($setting in @(
            @('user.email', 'driver-test@example.invalid'), @('user.name', 'Driver Test'), @('core.autocrlf', 'false'),
            @('maintenance.auto', 'false'), @('maintenance.autoDetach', 'false'), @('gc.auto', '0'), @('gc.autoDetach', 'false'),
            @('commit.gpgsign', 'false'))) {
            & $script:GitPath -C $Root config --local $setting[0] $setting[1]
        }
    }

    function Invoke-TestGitCommit {
        param([Parameter(Mandatory)][string] $Root, [Parameter(Mandatory)][string] $Message)
        & $script:GitPath -C $Root add -A
        & $script:GitPath -C $Root commit --quiet -m $Message
        if ($LASTEXITCODE -ne 0) { throw 'Test fixture commit failed.' }
        return ([string](& $script:GitPath -C $Root rev-parse HEAD)).Trim()
    }

    function Set-TestDriverCaptureRoot {
        param([Parameter(Mandatory)][string]$Root)
        & $script:DriverModule { param($CaptureRoot) $script:DarktideProcessCaptureRoot = $CaptureRoot } $Root
    }
}

Describe 'Darktide protected Core v2 source driver authority tuple' {
    It 'UnitT00_binds_the_exact_fbdc793_tuple_with_the_complete_51_file_inventory' {
        $pin = Get-DarktideSourceAuthorityPin
        $pin.repository | Should -BeExactly 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $pin.commit | Should -BeExactly 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
        $pin.archiveSha256 | Should -BeExactly 'c6bf36892d419c6751aeb2fde678e71975e2cec5448350e3700c337cd7a10c3d'
        $pin.archiveUrl | Should -BeExactly 'https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/fbdc793c1c439b15c6def97d53111f250d0ff4db'
        $pin.files.Count | Should -Be 51
        foreach ($required in @('scripts/Invoke-StandardValidation.ps1', 'scripts/Resolve-StandardValidationTool.ps1',
            'docs/standards/validation-security-gate.json', 'scripts/platform-runtime.psd1', 'scripts/platform-runtime.psm1',
            'scripts/platform/UnixNative.cs', 'scripts/platform/MacOS.psm1', 'scripts/platform/Linux.psm1', 'scripts/platform/Windows.psm1')) {
            $pin.files.Keys | Should -Contain $required
        }
        foreach ($hash in $pin.files.Values) { $hash | Should -MatchExactly '^[0-9a-f]{64}$' }
        $pin.files['scripts/Invoke-StandardValidation.ps1'] | Should -BeExactly '776c35c2f4c3a3fb61b6920e38e127b7a05b4a13e865b0aa9d2b4d1347e97624'
    }

    It 'UnitT01_keeps_the_active_v1_pin_independent_of_the_prepared_tuple' {
        $config = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/standard-v1.json') -Raw | ConvertFrom-Json -Depth 30
        $config.authority.commit | Should -BeExactly 'ead467c3488c103546f316d137196b447a1ff58a'
        @($config.authority.files).Count | Should -Be 33
        (Assert-DarktideActiveV1AuthorityConfig -Config $config).commit | Should -BeExactly 'ead467c3488c103546f316d137196b447a1ff58a'
        Assert-TestThrowsLike { Assert-DarktideSourceAuthorityConfig -Config $config } '*commit does not match the exact approved tuple*'
        (Get-Content -LiteralPath $script:ValidatePath -Raw) | Should -Match "approvedAuthorityCommit = 'ead467c3488c103546f316d137196b447a1ff58a'"
    }

    It 'UnitT02_accepts_the_complete_prepared_tuple_and_config' {
        $authority = New-TestAuthorityObject
        (Assert-DarktideSourceAuthorityTuple -Authority $authority).commit | Should -BeExactly 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
        $config = [pscustomobject][ordered]@{ schemaVersion = 1; standardVersion = 'v1'; authority = $authority; deviations = 'None' }
        (Assert-DarktideSourceAuthorityConfig -Config $config).files.Count | Should -Be 51
        $config.deviations = 'Some'
        Assert-TestThrowsLike { Assert-DarktideSourceAuthorityConfig -Config $config } '*deviation contract*'
    }

    It 'UnitT03_rejects_mixed_or_incomplete_tuple_<Mutation>' -ForEach @(
        @{ Mutation = 'missing-file'; Pattern = '*file tuple is incomplete*' }
        @{ Mutation = 'extra-file'; Pattern = '*file tuple is incomplete*' }
        @{ Mutation = 'duplicate-file'; Pattern = '*duplicate file path*' }
        @{ Mutation = 'altered-hash'; Pattern = '*file identity mismatch*' }
        @{ Mutation = 'reordered'; Pattern = '*path or order mismatch*' }
        @{ Mutation = 'unsafe-path'; Pattern = '*unsafe file path*' }
        @{ Mutation = 'wrong-commit'; Pattern = '*commit does not match*' }
        @{ Mutation = 'wrong-archive'; Pattern = '*archiveSha256 does not match*' }
        @{ Mutation = 'wrong-url'; Pattern = '*archiveUrl does not match*' }
        @{ Mutation = 'extra-property'; Pattern = '*invalid property set*' }
    ) {
        $authority = New-TestAuthorityObject
        $files = [Collections.Generic.List[object]]::new()
        foreach ($file in $authority.files) { $files.Add($file) }
        switch ($Mutation) {
            'missing-file' { $files.RemoveAt(10) }
            'extra-file' { $files.Add([pscustomobject][ordered]@{ path = 'docs/extra.md'; sha256 = ('0' * 64) }) }
            'duplicate-file' { $files[1] = [pscustomobject][ordered]@{ path = [string]$files[0].path; sha256 = [string]$files[0].sha256 } }
            'altered-hash' { $files[5] = [pscustomobject][ordered]@{ path = [string]$files[5].path; sha256 = ('a' * 64) } }
            'reordered' { $first = $files[0]; $files[0] = $files[1]; $files[1] = $first }
            'unsafe-path' { $files[3] = [pscustomobject][ordered]@{ path = '../escape.md'; sha256 = [string]$files[3].sha256 } }
            'wrong-commit' { $authority.commit = 'ead467c3488c103546f316d137196b447a1ff58a' }
            'wrong-archive' { $authority.archiveSha256 = 'ab304bc6caabe4bb9b605f403c852650e19e25f72999010db61bbad695e1c60b' }
            'wrong-url' { $authority.archiveUrl = 'https://example.invalid/archive.zip' }
            'extra-property' { $authority | Add-Member -NotePropertyName extra -NotePropertyValue 1 }
        }
        $authority.files = $files.ToArray()
        Assert-TestThrowsLike { Assert-DarktideSourceAuthorityTuple -Authority $authority } $Pattern
    }
}

Describe 'Darktide Core v2 route and Validate.ps1 dispatch' {
    It 'UnitT10_routes_only_explicit_AdapterVersion_2_source_purposes' {
        (Resolve-DarktideSourceRoute).mode | Should -BeExactly 'v1'
        $setup = Resolve-DarktideSourceRoute -AdapterVersion 2 -PrepareSourceTools -SourceToolsPath 'a' -AuthorityRepositoryRoot 'b' -TrustedToolRoot 'c'
        $setup.mode | Should -BeExactly 'prepare-source-tools'
        $setup.authority.commit | Should -BeExactly 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
        (Resolve-DarktideSourceRoute -AdapterVersion 2 -SourceValidation -SourceToolsPath 'a' -AuthorityRepositoryRoot 'b' -TrustedToolRoot 'c').mode | Should -BeExactly 'source-validation'
    }

    It 'UnitT11_rejects_invalid_route_requests_<Name>' -ForEach @(
        @{ Name = 'v2-params-without-purpose'; Splat = @{ AdapterVersion = 2; BoundParameters = @{ AdapterVersion = 2 } }; Pattern = '*only valid with -AdapterVersion 2*' }
        @{ Name = 'paths-without-purpose'; Splat = @{ SourceToolsPath = 'a'; BoundParameters = @{ SourceToolsPath = 'a' } }; Pattern = '*only valid with -AdapterVersion 2*' }
        @{ Name = 'purpose-without-v2'; Splat = @{ PrepareSourceTools = $true; SourceToolsPath = 'a'; AuthorityRepositoryRoot = 'b'; TrustedToolRoot = 'c' }; Pattern = '*require -AdapterVersion 2*' }
        @{ Name = 'mixed-purposes'; Splat = @{ AdapterVersion = 2; PrepareSourceTools = $true; SourceValidation = $true; SourceToolsPath = 'a'; AuthorityRepositoryRoot = 'b'; TrustedToolRoot = 'c' }; Pattern = '*separate setup and execution*' }
        @{ Name = 'missing-tools-path'; Splat = @{ AdapterVersion = 2; SourceValidation = $true; AuthorityRepositoryRoot = 'b'; TrustedToolRoot = 'c' }; Pattern = '*requires SourceToolsPath*' }
        @{ Name = 'missing-authority-root'; Splat = @{ AdapterVersion = 2; SourceValidation = $true; SourceToolsPath = 'a'; TrustedToolRoot = 'c' }; Pattern = '*requires AuthorityRepositoryRoot*' }
        @{ Name = 'missing-trusted-root'; Splat = @{ AdapterVersion = 2; SourceValidation = $true; SourceToolsPath = 'a'; AuthorityRepositoryRoot = 'b' }; Pattern = '*requires TrustedToolRoot*' }
        @{ Name = 'v1-archive'; Splat = @{ AdapterVersion = 2; SourceValidation = $true; SourceToolsPath = 'a'; AuthorityRepositoryRoot = 'b'; TrustedToolRoot = 'c'; BoundParameters = @{ AuthorityArchivePath = 'x' } }; Pattern = '*do not accept v1 parameters: AuthorityArchivePath*' }
        @{ Name = 'v1-pester'; Splat = @{ AdapterVersion = 2; SourceValidation = $true; SourceToolsPath = 'a'; AuthorityRepositoryRoot = 'b'; TrustedToolRoot = 'c'; BoundParameters = @{ PesterWorkerPath = 'x' } }; Pattern = '*do not accept v1 parameters: PesterWorkerPath*' }
    ) {
        Assert-TestThrowsLike { Resolve-DarktideSourceRoute @Splat } $Pattern
    }

    It 'UnitT12_dispatches_v2_before_the_v1_windows_gate_and_any_native_type' {
        $text = Get-Content -LiteralPath $script:ValidatePath -Raw
        $dispatch = $text.IndexOf("Import-Module -Name (Join-Path `$PSScriptRoot 'StandardSourceDriver.psm1')", [StringComparison]::Ordinal)
        $gate = $text.IndexOf("throw 'Standard v1 validation requires Windows with PowerShell 7.'", [StringComparison]::Ordinal)
        $firstAddType = $text.IndexOf('Add-Type', [StringComparison]::Ordinal)
        $firstFunction = [regex]::Match($text, '(?m)^function ').Index
        $dispatch | Should -BeGreaterThan 0
        $gate | Should -BeGreaterThan $dispatch
        $firstAddType | Should -BeGreaterThan $dispatch
        $firstFunction | Should -BeGreaterThan $dispatch
        (Get-Content -LiteralPath $script:DriverPath -Raw) | Should -Not -Match 'Add-Type|kernel32|advapi32|DllImport'
        (Get-Content -LiteralPath $script:ChildPath -Raw) | Should -Not -Match 'Add-Type|kernel32|advapi32|DllImport'
    }

    It 'UnitT13_keeps_ead467c_active_while_v2_advances_to_prepared_authority_setup' {
        $artifacts = Join-Path $TestDrive ('artifacts-' + [guid]::NewGuid().ToString('N'))
        $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $script:ValidatePath -AdapterVersion 2 -PrepareSourceTools `
            -SourceToolsPath (Join-Path $artifacts 'source-tools.json') -AuthorityRepositoryRoot $TestDrive -TrustedToolRoot $TestDrive -ArtifactsRoot $artifacts 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Not -BeLike '*Prepared source authority commit does not match the exact approved tuple*'
        ($output -join "`n") | Should -BeLike '*approved CI run-owned root*'
        ($output -join "`n") | Should -Not -BeLike '*requires Windows*'
        Test-Path -LiteralPath $artifacts | Should -BeFalse
    }

    It 'UnitT14_rejects_v2_parameters_without_a_source_purpose_through_Validate' {
        $previousPath = $env:DT_TEST_VALIDATE_PATH
        try {
            $env:DT_TEST_VALIDATE_PATH = $script:ValidatePath
            $exceptionMessageCommand = 'try { & $env:DT_TEST_VALIDATE_PATH -AdapterVersion 2 } catch { [Console]::Out.WriteLine($_.Exception.Message); exit 1 }'
            $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -Command $exceptionMessageCommand 2>&1)
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -BeLike '*only valid with -AdapterVersion 2 and an explicit source purpose*'
        }
        finally { $env:DT_TEST_VALIDATE_PATH = $previousPath }
    }

    It 'UnitT15_preserves_the_v1_modes_and_gate_unchanged' {
        $text = Get-Content -LiteralPath $script:ValidatePath -Raw
        foreach ($name in @('BootstrapTransition', 'EnableSemanticScan', 'ProtectedPesterServerProxy', 'ProtectedPesterSupervisor', 'TrustedTestCommit', 'AuthorityArchivePath')) {
            $text | Should -Match ('\[switch\] \$' + $name + '|\[string\] \$' + $name)
        }
        $text | Should -Match "(?m)^if \(-not \`$script:IsWindowsHost\) \{\r?\n    throw 'Standard v1 validation requires Windows with PowerShell 7\.'"
        $text | Should -Match 'if \(\$ProtectedPesterServerProxy\) \{'
        $text | Should -Match 'if \(\$ProtectedPesterSupervisor\) \{'
        $text | Should -Match 'if \(\$BootstrapTransition\) \{'
        $text | Should -Match "Darktide Translate Standard v1 canonical validation passed\. Evidence: "
    }

    if (-not $IsWindows) {
        It 'UnitT16_keeps_the_v1_canonical_path_windows_only_on_unix_hosts' {
            $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $script:ValidatePath 2>&1)
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -BeLike '*Standard v1 validation requires Windows with PowerShell 7.*'
        }
    }
    if ($IsWindows) {
        It 'UnitT16W_keeps_the_v1_route_reachable_for_v1_only_parameters_on_windows' {
            # A v1-only invocation never loads the Core v2 driver module.
            $route = Resolve-DarktideSourceRoute -BoundParameters @{ BootstrapTransition = $true }
            $route.mode | Should -BeExactly 'v1'
        }
    }

    It 'UnitT17_canonicalizes_the_trusted_root_but_rejects_links_below_it' {
        $physicalRoot = Join-Path $TestDrive ('physical-' + [guid]::NewGuid().ToString('N'))
        $outsideRoot = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $physicalRoot, $outsideRoot | Out-Null
        $logicalRoot = Join-Path $TestDrive ('logical-' + [guid]::NewGuid().ToString('N'))
        [void](New-TestReparsePoint -Path $logicalRoot -Target $physicalRoot)
        $ordinary = Join-Path $physicalRoot 'ordinary'
        New-Item -ItemType Directory -Path $ordinary | Out-Null
        $module = Get-Module -Name StandardSourceDriver -ErrorAction Stop

        { & $module { param($Path, $Root) Assert-DarktideNoReparseAncestors -Path $Path -Context 'fixture' -TrustedRoot $Root } $ordinary $logicalRoot } |
            Should -Not -Throw

        $linked = Join-Path $physicalRoot 'linked'
        [void](New-TestReparsePoint -Path $linked -Target $outsideRoot)
        { & $module { param($Path, $Root) Assert-DarktideNoReparseAncestors -Path $Path -Context 'fixture' -TrustedRoot $Root } $linked $logicalRoot } |
            Should -Throw '*reparse point*'
    }
}

Describe 'Darktide Core v2 adapter, dispatch and protected readers' {
    It 'UnitT20_builds_the_exact_standard_core_adapter_v2' {
        $sourceValidation = [ordered]@{ marker = 'kept' }
        $adapter = New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @('auto-update-darktide-mod') -SourceValidation $sourceValidation `
            -AuthorityRevision ('f' * 40)
        $adapter.schemaVersion | Should -Be 2
        $adapter.adapter | Should -BeExactly 'standard-core-adapter-v2'
        $adapter.skillsRoot | Should -BeExactly 'skills'
        @($adapter.activeSkills) | Should -Be @('auto-update-darktide-mod')
        @($adapter.checks).Count | Should -Be 2
        $adapter.checks[0].id | Should -BeExactly 'repository-general'
        $adapter.checks[0].kind | Should -BeExactly 'general'
        @($adapter.checks[0].arguments) | Should -Be @('-NoProfile', '-NonInteractive', '-File', 'scripts/Test-Repository.ps1', '-ReadOnlySnapshot')
        $adapter.checks[1].id | Should -BeExactly 'repository-pester'
        $adapter.checks[1].kind | Should -BeExactly 'pester'
        @($adapter.checks[1].arguments) | Should -Be @('-NoProfile', '-NonInteractive', '-File', 'scripts/Invoke-CorePester.ps1', '-AuthorityRevision', ('f' * 40))
        @($adapter.checks | ForEach-Object { @($_.arguments | Where-Object { [IO.Path]::IsPathRooted([string]$_) }).Count } | Measure-Object -Sum).Sum | Should -Be 0
        foreach ($check in $adapter.checks) {
            $check.executable | Should -BeExactly $script:PowerShellPath
            $check.executableSha256 | Should -BeExactly (Get-FileHash -LiteralPath $script:PowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $adapter.sourceValidation.marker | Should -BeExactly 'kept'
        Assert-TestThrowsLike { New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @() -SourceValidation $sourceValidation -AuthorityRevision ('f' * 40) } '*at least one active Skill*'
        Assert-TestThrowsLike { New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @('Bad_Id') -SourceValidation $sourceValidation -AuthorityRevision ('f' * 40) } '*invalid Skill ID*'
    }

    It 'UnitT21_dispatches_each_slot_to_one_child_mode' {
        $arguments = Get-DarktideSourceDispatchArguments -ChildPath 'C' -ToolchainPath 'T' -ToolchainSha256 ('b' * 64) `
            -DriverModulePath 'D' -DriverModuleSha256 ('d' * 64) -AuthorityRuntimeManifestPath 'M' -AuthorityRevision ('f' * 40) -TimeoutSeconds 42
        @($arguments.Keys) | Should -Be @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')
        $modes = @{ packageAdapter = 'package-adapter'; skillValidator = 'skill-validator'; skillTools = 'skill-tools'; staticAnalyzer = 'static' }
        foreach ($slot in $modes.Keys) {
            @($arguments[$slot]) | Should -Be @('-NoProfile', '-NonInteractive', '-File', 'C', '-ToolchainPath', 'T', '-ToolchainSha256', ('b' * 64), '-DriverModulePath', 'D', '-DriverModuleSha256', ('d' * 64), '-AuthorityRuntimeManifestPath', 'M', '-AuthorityRevision', ('f' * 40), '-TimeoutSeconds', '42', '-Mode', $modes[$slot])
        }
    }

    # Scenario: The complete generated adapter is submitted to the exact fbdc793 Core v2 adapter-validation functions.
    # Purpose: Prove every generated check and source command satisfies the authority runner's path and frozen-file contracts.
    It 'InterT22_passes_the_complete_generated_adapter_through_the_fbdc793_validator' {
        $candidate=Join-Path $TestDrive 'candidate'; $artifacts=Join-Path $TestDrive 'artifacts'; $owned=Join-Path $TestDrive 'owned'
        New-Item -ItemType Directory -Path $candidate,$artifacts,$owned | Out-Null
        $child=Join-Path $owned 'Invoke-SourceChild.ps1'; $driver=Join-Path $owned 'ProtectedSourceDriver.psm1'; $toolchain=Join-Path $owned 'toolchain.json'
        Copy-Item -LiteralPath $script:ChildPath -Destination $child
        Copy-Item -LiteralPath $script:DriverPath -Destination $driver
        [IO.File]::WriteAllText($toolchain,'{}',[Text.UTF8Encoding]::new($false))
        $manifest=Join-Path $script:AuthorityRoot 'scripts/platform-runtime.psd1'
        $dispatch=Get-DarktideSourceDispatchArguments -ChildPath $child -ToolchainPath $toolchain -ToolchainSha256 ((Get-FileHash $toolchain -Algorithm SHA256).Hash.ToLowerInvariant()) `
            -DriverModulePath $driver -DriverModuleSha256 ((Get-FileHash $driver -Algorithm SHA256).Hash.ToLowerInvariant()) `
            -AuthorityRuntimeManifestPath $manifest -AuthorityRevision 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
        $frozen=@($script:PowerShellPath,$child,$driver,$toolchain,$manifest | ForEach-Object { [pscustomobject]@{path=[IO.Path]::GetFullPath($_);sha256=(Get-FileHash $_ -Algorithm SHA256).Hash.ToLowerInvariant()} })
        $source=[ordered]@{frozenFiles=$frozen;toolReceipts=@()}
        foreach($slot in @('packageAdapter','skillValidator','skillTools','staticAnalyzer')){$source[$slot]=[ordered]@{command=$script:PowerShellPath;arguments=@($dispatch[$slot])}}
        $adapter=New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @('auto-update-darktide-mod') -SourceValidation $source -AuthorityRevision 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
        $runner=Join-Path $script:AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
        . $runner -DefineFunctionsOnly -CandidateRoot $candidate -AdapterPath (Join-Path $owned 'adapter.json') -ArtifactsRoot $artifacts `
            -SourceRepository 'https://example.invalid/repo.git' -SourceRevision ('a'*40) -BaseRevision ('b'*40) -AuthorityRevision 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
        foreach($check in @($adapter.checks)) {
            foreach($argument in @($check.arguments)) {
                [IO.Path]::IsPathRooted([string]$argument) | Should -BeFalse
                if(([string]$argument).Contains('/') -or ([string]$argument).Contains([char]92)){ { Assert-StandardValidationSafeRelativePath -Value ([string]$argument) -Context 'generated check argument' } | Should -Not -Throw }
            }
        }
        Assert-StandardCoreFrozenFiles -Files $frozen
        foreach($slot in @('packageAdapter','skillValidator','skillTools','staticAnalyzer')) {
            { Assert-StandardValidationCommandSpec -Spec ([pscustomobject]$adapter.sourceValidation.$slot) -Context "source $slot" -CandidateRoot $candidate -ArtifactsRoot $artifacts -TrustedToolRoot $PSHOME -TrustAnchorRoot $PSHOME -ExpectedToolName $slot -DevelopmentHarness $true } | Should -Not -Throw
            foreach($argument in @($adapter.sourceValidation.$slot.arguments | Where-Object { [IO.Path]::IsPathRooted([string]$_) })) {
                @($adapter.sourceValidation.frozenFiles | Where-Object path -CEQ ([IO.Path]::GetFullPath([string]$argument))).Count | Should -Be 1
            }
        }
    }

    It 'UnitT23_child_runner_exposes_only_the_four_source_modes_without_semantic_escalation' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:ChildPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $modeParameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Mode' })[0]
        $validateSet = @($modeParameter.Attributes | Where-Object { $_.TypeName.Name -ceq 'ValidateSet' })[0]
        @($validateSet.PositionalArguments | ForEach-Object { $_.Value }) | Should -Be @('package-adapter', 'skill-validator', 'skill-tools', 'static')
        $text = Get-Content -LiteralPath $script:ChildPath -Raw
        $text | Should -Not -Match 'semanticRequired = \$true|SemanticRequired -ceq'
        $text | Should -Match "scannerIdentity = 'SkillSpector'; analyzerCompleteness = 'complete'; semanticRequired = \`$false"
        $text | Should -Match "SKILLSPECTOR_MAX_WORKFLOW_SECONDS = '1200'"
        $text | Should -Match "'check', '--strict', '--allow-dirs=agents', '-o', 'json'"
        $text | Should -Match "'route', \[string\]\`$routeCase\.query, '--skills', \`$skillsRoot, '--top-k', '1', '--format', 'json'"
        $text | Should -Match "'-o', 'json', 'validate', 'structure', '--allow-dirs=agents', \`$skillRoot"
        $text | Should -Match "'scan', \`$skillRoot, '--no-llm', '--format', 'json'"
    }

    It 'UnitT24_requires_candidate_protected_readers_to_equal_the_driver_bytes' {
        $base = Join-Path $TestDrive ('base-' + [guid]::NewGuid().ToString('N'))
        $candidate = Join-Path $TestDrive ('candidate-' + [guid]::NewGuid().ToString('N'))
        $readers = @('scripts/Test-Repository.ps1', 'scripts/Invoke-CorePester.ps1', 'scripts/CorePesterIntegrity.psm1', 'config/pester-6.2.0-closure.lock.json')
        foreach ($root in @($base, $candidate)) {
            foreach ($relative in $readers) {
                $target = Join-Path $root $relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relative) -Destination $target
            }
        }
        $bindings = @(Assert-DarktideSourceProtectedReaders -ProtectedBaseRoot $base -CandidateRoot $candidate)
        @($bindings | ForEach-Object { $_.path }) | Should -Be $readers
        Add-Content -LiteralPath (Join-Path $candidate 'scripts/Invoke-CorePester.ps1') -Value '# weakened'
        Assert-TestThrowsLike { Assert-DarktideSourceProtectedReaders -ProtectedBaseRoot $base -CandidateRoot $candidate } '*differs from the trusted driver bytes: scripts/Invoke-CorePester.ps1*'
        Remove-Item -LiteralPath (Join-Path $candidate 'scripts/Invoke-CorePester.ps1')
        Assert-TestThrowsLike { Assert-DarktideSourceProtectedReaders -ProtectedBaseRoot $base -CandidateRoot $candidate } '*Protected reader is missing*'
    }

    It 'UnitT25_protected_readers_of_this_checkout_are_self_consistent' {
        @(Assert-DarktideSourceProtectedReaders -ProtectedBaseRoot $script:RepositoryRoot -CandidateRoot $script:RepositoryRoot).Count | Should -Be 4
        (Get-DarktideSourceChildRunnerPath) | Should -BeExactly ([IO.Path]::GetFullPath($script:ChildPath))
    }

    It 'UnitT26_reads_the_strict_active_skill_inventory' {
        @(Get-DarktideActiveSkillIds -Root $script:RepositoryRoot) | Should -Be @('auto-update-darktide-mod')
        $fixture = Join-Path $TestDrive ('inventory-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $fixture 'catalog'), (Join-Path $fixture 'skills/auto-update-darktide-mod'), (Join-Path $fixture 'skills/extra-skill') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') -Destination (Join-Path $fixture 'catalog/source.json')
        Assert-TestThrowsLike { Get-DarktideActiveSkillIds -Root $fixture } '*does not exactly match skills/ directories*'
    }

    # Scenario: Candidate PathSafety and StandardSourceDriver modules contain import-time side effects.
    # Purpose: Prove the protected child imports only the frozen protected-base driver and authority runtime.
    It 'InterT27_ignores_candidate_control_plane_module_tampering' {
        $candidate = Join-Path $TestDrive 'candidate-tamper'
        $marker = Join-Path $TestDrive 'candidate-module-executed.txt'
        foreach ($relative in @('skills/auto-update-darktide-mod/scripts/PathSafety.psm1','scripts/StandardSourceDriver.psm1')) {
            $path = Join-Path $candidate $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','executed')`nthrow 'candidate module executed'`n")
        }
        $missingToolchain = Join-Path $TestDrive 'missing-toolchain.json'
        $previousCandidate = $env:STANDARD_VALIDATION_CANDIDATE_ROOT
        try {
            $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $candidate
            $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $script:ChildPath `
                -Mode skill-validator -ToolchainPath $missingToolchain -ToolchainSha256 ('0' * 64) `
                -DriverModulePath $script:DriverPath -DriverModuleSha256 ((Get-FileHash -LiteralPath $script:DriverPath -Algorithm SHA256).Hash.ToLowerInvariant()) `
                -AuthorityRuntimeManifestPath (Join-Path $script:AuthorityRoot 'scripts/platform-runtime.psd1') -AuthorityRevision 'fbdc793c1c439b15c6def97d53111f250d0ff4db' 2>&1)
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Not -Match 'candidate module executed'
            Test-Path -LiteralPath $marker | Should -BeFalse
        }
        finally { $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $previousCandidate }
    }
}

Describe 'Darktide Core v2 frozen receipts, timing and whitespace gate' {
    BeforeAll {
        function New-ReceiptFixture {
            param([Parameter(Mandatory)][string] $Root)
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            $tool = Join-Path $Root 'tool.bin'; [IO.File]::WriteAllText($tool, 'tool')
            $node = Join-Path $Root 'node.bin'; [IO.File]::WriteAllText($node, 'node')
            $entry = Join-Path $Root 'entry.js'; [IO.File]::WriteAllText($entry, 'entry')
            $spector = Join-Path $Root 'spector.bin'; [IO.File]::WriteAllText($spector, 'spector')
            $hash = { param($p) (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
            $receipts = @(
                @{ name = 'skill-validator'; value = [ordered]@{ toolName = 'skill-validator'; executablePath = $tool; executableSha256 = (& $hash $tool) } }
                @{ name = 'skill-tools'; value = [ordered]@{ toolName = 'skill-tools'; nodePath = $node; nodeSha256 = (& $hash $node); entryPointPath = $entry; entryPointSha256 = (& $hash $entry) } }
                @{ name = 'skillspector'; value = [ordered]@{ toolName = 'skillspector'; executablePath = $spector; executableSha256 = (& $hash $spector) } }
            )
            $bindings = @(); $frozen = @()
            foreach ($receipt in $receipts) {
                $path = Join-Path $Root "receipt-$($receipt.name).json"
                [IO.File]::WriteAllText($path, ($receipt.value | ConvertTo-Json))
                $bindings += [pscustomobject]@{ path = [IO.Path]::GetFullPath($path); sha256 = (& $hash $path) }
            }
            foreach ($file in @($tool, $node, $entry, $spector) + @($bindings | ForEach-Object { $_.path })) {
                $frozen += [pscustomobject]@{ path = [IO.Path]::GetFullPath($file); sha256 = (& $hash $file) }
            }
            return [pscustomobject]@{ bindings = $bindings; frozen = $frozen; tool = $tool }
        }
    }

    # Scenario: The workflow supplies an explicit stable Go version or an invalid stable-channel value.
    # Purpose: Accept only stable semantic versions before any resolver dispatch is created.
    It 'UnitT27_accepts_stable_and_rejects_prerelease_or_malformed_Go_versions' {
        $module=$script:DriverModule
        (& $module { Resolve-DarktideGoRuntimeVersion -Expected '1.24.3' }) | Should -BeExactly '1.24.3'
        foreach($invalid in @('1.24.0-rc.1','go1.24.3','1.24','latest')) {
            Assert-TestThrowsLike { & $module { param($Value) Resolve-DarktideGoRuntimeVersion -Expected $Value } $invalid } '*stable semantic Go version*'
        }
    }

    # Scenario: A controlled go version process succeeds, exits non-zero, emits malformed output, or exceeds its deadline.
    # Purpose: Bind automatic resolution to one exact stable result and fail closed on every process failure mode.
    It 'UnitT28_controls_go_version_<Scenario>' -ForEach @(
        @{Scenario='success';ExitCode=0;Stdout="go version go1.24.3 windows/amd64`n";Throws=$false;Pattern=''},
        @{Scenario='nonzero';ExitCode=9;Stdout='';Throws=$true;Pattern='*exited with code 9*'},
        @{Scenario='malformed';ExitCode=0;Stdout="go version devel go1.25-deadbeef windows/amd64`n";Throws=$true;Pattern='*Could not resolve the current stable Go runtime version*'}
    ) {
        $module=$script:DriverModule; $commandPath=$script:PowerShellPath
        $resolver={ [pscustomobject]@{Path=$commandPath} }.GetNewClosure()
        $invoker={ param($Path,$Arguments) [pscustomobject]@{exitCode=$ExitCode;stdout=$Stdout;stderr=''} }.GetNewClosure()
        if($Throws){ Assert-TestThrowsLike { & $module { param($Resolve,$Invoke) Resolve-DarktideGoRuntimeVersion -CommandResolver $Resolve -ProcessInvoker $Invoke } $resolver $invoker } $Pattern }
        else { (& $module { param($Resolve,$Invoke) Resolve-DarktideGoRuntimeVersion -CommandResolver $Resolve -ProcessInvoker $Invoke } $resolver $invoker) | Should -BeExactly '1.24.3' }
    }

    It 'UnitT29_fails_closed_when_controlled_go_version_times_out_and_binds_the_result_to_every_resolver' {
        $module=$script:DriverModule; $commandPath=$script:PowerShellPath
        $resolver={ [pscustomobject]@{Path=$commandPath} }.GetNewClosure()
        $invoker={ throw 'Owned process exceeded its 1 second deadline.' }
        Assert-TestThrowsLike { & $module { param($Resolve,$Invoke) Resolve-DarktideGoRuntimeVersion -CommandResolver $Resolve -ProcessInvoker $Invoke } $resolver $invoker } '*exceeded its 1 second deadline*'
        $driverText=Get-Content -LiteralPath $script:DriverPath -Raw
        $driverText | Should -Match "foreach \(\`$tool in \`$script:DarktideSourceToolNames\)"
        $driverText | Should -Match "'-ExpectedGoRuntimeVersion', \`$GoVersion"
    }

    It 'UnitT30_requires_every_receipt_and_tool_payload_frozen_exactly_once' {
        $fixture = New-ReceiptFixture -Root (Join-Path $TestDrive ('receipts-' + [guid]::NewGuid().ToString('N')))
        { Assert-DarktideSourceReceiptClosureFrozen -Bindings $fixture.bindings -FrozenFiles $fixture.frozen } | Should -Not -Throw
        Assert-TestThrowsLike { Assert-DarktideSourceReceiptClosureFrozen -Bindings @($fixture.bindings | Select-Object -First 2) -FrozenFiles $fixture.frozen } '*exactly three resolver receipts*'
        $withoutTool = @($fixture.frozen | Where-Object { $_.path -ne [IO.Path]::GetFullPath($fixture.tool) })
        Assert-TestThrowsLike { Assert-DarktideSourceReceiptClosureFrozen -Bindings $fixture.bindings -FrozenFiles $withoutTool } '*executablePath is not frozen exactly once*'
        $duplicate = @($fixture.frozen) + @($fixture.frozen[0])
        Assert-TestThrowsLike { Assert-DarktideSourceReceiptClosureFrozen -Bindings $fixture.bindings -FrozenFiles $duplicate } '*unique absolute paths*'
        [IO.File]::AppendAllText($fixture.bindings[0].path, ' ')
        Assert-TestThrowsLike { Assert-DarktideSourceReceiptClosureFrozen -Bindings $fixture.bindings -FrozenFiles $fixture.frozen } '*does not match its frozen SHA-256 binding*'
    }

    It 'UnitT31_writes_a_create_only_structured_timing_sidecar' {
        $path = Join-Path $TestDrive ('timing-' + [guid]::NewGuid().ToString('N') + '.json')
        $lines = @(
            'noise',
            '[StandardValidation timing] {"stage":"core","phase":"candidate-inventory","state":"completed","calls":1,"files":2,"bytes":3,"elapsedSeconds":0.5}'
        )
        [void](Write-DarktideSourceTimingSidecar -Path $path -OutputLines $lines -RunId ('a' * 32) -SourceRevision ('b' * 40) -BaseRevision ('c' * 40) -AuthorityRevision ('d' * 40))
        $sidecar = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $sidecar.report | Should -BeExactly 'standard-core-source-timing-v1'
        @($sidecar.records).Count | Should -Be 1
        { Write-DarktideSourceTimingSidecar -Path $path -OutputLines $lines -RunId ('a' * 32) -SourceRevision ('b' * 40) -BaseRevision ('c' * 40) -AuthorityRevision ('d' * 40) } | Should -Throw
        $other = Join-Path $TestDrive ('timing-' + [guid]::NewGuid().ToString('N') + '.json')
        Assert-TestThrowsLike { Write-DarktideSourceTimingSidecar -Path $other -OutputLines $lines -RunId ('a' * 32) -SourceRevision ('b' * 40) -BaseRevision ('c' * 40) -AuthorityRevision ('d' * 40) -RequireCoreEvidence } "*omitted completed 'file-inventory'*"
    }

    It 'UnitT32_scopes_the_setup_token_to_the_resolver_environment' {
        $previous = @{}
        foreach ($name in @('DT_SOURCE_SETUP_GITHUB_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN')) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            $env:DT_SOURCE_SETUP_GITHUB_TOKEN = 'setup-token'; $env:GITHUB_TOKEN = 'job-token'; $env:GH_TOKEN = 'gh-token'
            $environment = Get-DarktideSourceResolverEnvironment -IncludeSetupToken
            $environment['STANDARD_VALIDATION_GITHUB_API_TOKEN'] | Should -BeExactly 'setup-token'
            @($environment.Keys).Count | Should -Be 1
            foreach ($name in @('DT_SOURCE_SETUP_GITHUB_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN')) { [Environment]::GetEnvironmentVariable($name, 'Process') | Should -BeNullOrEmpty }
            $env:DT_SOURCE_SETUP_GITHUB_TOKEN = 'setup-token'
            @((Get-DarktideSourceResolverEnvironment).Keys).Count | Should -Be 0
            $env:DT_SOURCE_SETUP_GITHUB_TOKEN | Should -BeNullOrEmpty
        }
        finally {
            foreach ($name in $previous.Keys) {
                if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
                else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
            }
        }
    }

    It 'UnitT33_enforces_the_v1_whitespace_check_over_the_event_range' {
        Set-TestDriverCaptureRoot -Root $TestDrive
        $root = Join-Path $TestDrive ('ws-' + [guid]::NewGuid().ToString('N'))
        New-TestGitRepository -Root $root
        [IO.File]::WriteAllText((Join-Path $root 'a.txt'), "clean`n")
        $base = Invoke-TestGitCommit -Root $root -Message 'base'
        [IO.File]::WriteAllText((Join-Path $root 'b.txt'), "still clean`n")
        $clean = Invoke-TestGitCommit -Root $root -Message 'clean'
        { Assert-DarktideCandidateWhitespace -GitPath $script:GitPath -RepositoryRoot $root -BaseRevision $base -CandidateRevision $clean } | Should -Not -Throw
        [IO.File]::WriteAllText((Join-Path $root 'c.txt'), "trailing   `n")
        $dirty = Invoke-TestGitCommit -Root $root -Message 'dirty'
        Assert-TestThrowsLike { Assert-DarktideCandidateWhitespace -GitPath $script:GitPath -RepositoryRoot $root -BaseRevision $base -CandidateRevision $dirty } '*Whitespace validation failed*'
    }

    It 'UnitT34_never_relaxes_outside_root_checks_by_case' {
        Test-DarktidePathOverlap -Path (Join-Path $TestDrive 'Root/Child') -Root (Join-Path $TestDrive 'root') | Should -BeTrue
        Test-DarktidePathOverlap -Path (Join-Path $TestDrive 'rootx') -Root (Join-Path $TestDrive 'root') | Should -BeFalse
    }
}

Describe 'Darktide prepared authority checkout binding' {
    It 'UnitT40_binds_head_origin_cleanliness_and_raw_blob_bytes' {
        Set-TestDriverCaptureRoot -Root $TestDrive
        $root = Join-Path $TestDrive ('authority-' + [guid]::NewGuid().ToString('N'))
        New-TestGitRepository -Root $root
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'docs/a.md'), "authority`n")
        $commit = Invoke-TestGitCommit -Root $root -Message 'authority'
        & $script:GitPath -C $root remote add origin 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        $pin = [pscustomobject]@{
            repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
            commit = $commit
            files = [ordered]@{ 'docs/a.md' = (Get-FileHash -LiteralPath (Join-Path $root 'docs/a.md') -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
        $checkout = Assert-DarktidePreparedAuthorityCheckout -GitPath $script:GitPath -AuthorityRoot $root -AuthorityPin $pin
        $checkout.revision | Should -BeExactly $commit
        $pin.files['docs/a.md'] = ('0' * 64)
        Assert-TestThrowsLike { Assert-DarktidePreparedAuthorityCheckout -GitPath $script:GitPath -AuthorityRoot $root -AuthorityPin $pin } '*file identity mismatch: docs/a.md*'
        $pin.files['docs/a.md'] = (Get-FileHash -LiteralPath (Join-Path $root 'docs/a.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        $pin.commit = ('1' * 40)
        Assert-TestThrowsLike { Assert-DarktidePreparedAuthorityCheckout -GitPath $script:GitPath -AuthorityRoot $root -AuthorityPin $pin } '*HEAD does not match*'
        $pin.commit = $commit
        & $script:GitPath -C $root remote set-url origin 'https://github.com/other/repo.git'
        Assert-TestThrowsLike { Assert-DarktidePreparedAuthorityCheckout -GitPath $script:GitPath -AuthorityRoot $root -AuthorityPin $pin } '*origin does not match*'
        & $script:GitPath -C $root remote set-url origin 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
        [IO.File]::WriteAllText((Join-Path $root 'untracked.txt'), 'x')
        Assert-TestThrowsLike { Assert-DarktidePreparedAuthorityCheckout -GitPath $script:GitPath -AuthorityRoot $root -AuthorityPin $pin } '*must be clean*'
    }

    It 'UnitT41_core_adapter_layout_is_a_direct_artifacts_child' {
        $layout = Get-DarktideCoreAdapterLayout -ArtifactsRoot $TestDrive -RunId ('e' * 32)
        Split-Path -Parent $layout.adapterRoot | Should -BeExactly ([IO.Path]::GetFullPath($TestDrive).TrimEnd([IO.Path]::DirectorySeparatorChar))
        [IO.Path]::GetFileName($layout.adapterPath) | Should -BeExactly 'standard-core-adapter-v2.json'
        Assert-TestThrowsLike { Get-DarktideCoreAdapterLayout -ArtifactsRoot $TestDrive -RunId 'short' } '*canonical source setup RunId*'
    }

    # Scenario: The same frozen source-tools setup is retried after an earlier source-validation attempt failed.
    # Purpose: Preserve failed evidence and guarantee that the retry cannot reuse either run-owned directory.
    It 'UnitT42_assigns_a_fresh_create_only_directory_pair_to_every_retry' {
        $setupRunId = 'a' * 32
        $first = New-DarktideSourceAttemptLayout -ArtifactsRoot $TestDrive -SetupRunId $setupRunId
        $second = New-DarktideSourceAttemptLayout -ArtifactsRoot $TestDrive -SetupRunId $setupRunId
        $first.attemptId | Should -Not -BeExactly $second.attemptId
        $first.artifactsRoot | Should -Not -BeExactly $second.artifactsRoot
        $first.adapter.adapterRoot | Should -Not -BeExactly $second.adapter.adapterRoot
        $first.artifactsRoot | Should -BeLike "*$setupRunId-$($first.attemptId)"
        (Get-Content -LiteralPath $script:DriverPath -Raw) | Should -Match 'No cleanup journal is needed|No cleanup journal'
    }

    # Scenario: Source purposes run locally, omit registration, or point outside the registered CI run root.
    # Purpose: Prevent retained attempt evidence from accumulating in shared or caller-selected directories.
    It 'UnitT43_rejects_unregistered_or_outside_CI_artifacts_roots' {
        (Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'scripts/Validate.ps1') -Raw) |
            Should -Not -Match 'Invoke-DarktideSourceEntryPoint[^\r\n]*DefaultArtifactsRoot'
        (Get-Content -LiteralPath $script:DriverPath -Raw) | Should -Not -Match 'DefaultArtifactsRoot'
        $oldActions=$env:GITHUB_ACTIONS; $oldOwned=$env:RUN_OWNED_ROOT
        try {
            $env:GITHUB_ACTIONS=$null; $env:RUN_OWNED_ROOT=$null
            Assert-TestThrowsLike { Open-DarktideRunOwnedArtifactsRoot -ArtifactsRoot $TestDrive } '*approved CI run-owned root*'
            $env:GITHUB_ACTIONS='true'
            Assert-TestThrowsLike { Open-DarktideRunOwnedArtifactsRoot -ArtifactsRoot $TestDrive } '*require RUN_OWNED_ROOT*'
            $owned=Join-Path $TestDrive 'owned'; $outside=Join-Path $TestDrive 'outside'
            New-Item -ItemType Directory -Path $owned,$outside | Out-Null
            $env:RUN_OWNED_ROOT=$owned
            Assert-TestThrowsLike { Open-DarktideRunOwnedArtifactsRoot -ArtifactsRoot $outside } '*within the registered RUN_OWNED_ROOT*'
            $artifacts=Join-Path $owned 'artifacts'; New-Item -ItemType Directory -Path $artifacts | Out-Null
            $binding=Open-DarktideRunOwnedArtifactsRoot -ArtifactsRoot $artifacts
            try {
                $binding.RunRoot | Should -BeExactly ([IO.Path]::GetFullPath($owned))
                $binding.ArtifactsRoot | Should -BeExactly ([IO.Path]::GetFullPath($artifacts))
                $binding.RunLease | Should -Not -BeNullOrEmpty
                $binding.ArtifactsLease | Should -Not -BeNullOrEmpty
            }
            finally { $binding.ArtifactsLease.Dispose(); $binding.RunLease.Dispose() }
        }
        finally { $env:GITHUB_ACTIONS=$oldActions; $env:RUN_OWNED_ROOT=$oldOwned }
    }

    # Scenario: A successful or failed canonical report is projected to a new stable caller path, while a prior path is preserved.
    # Purpose: Decouple public OutputPath from the unpredictable attempt directory without permitting replacement.
    It 'UnitT44_projects_success_and_failure_reports_create_only' {
        $attemptRoot=Join-Path $TestDrive 'attempt'; $outputRoot=Join-Path $TestDrive 'outputs'
        New-Item -ItemType Directory -Path $attemptRoot,$outputRoot | Out-Null
        foreach($case in @(@{Name='success';Json='{"result":"passed"}'},@{Name='failure';Json='{"result":"failed"}'})) {
            $source=Join-Path $attemptRoot "$($case.Name).json"; $target=Join-Path $outputRoot "$($case.Name).json"
            [IO.File]::WriteAllText($source,$case.Json,[Text.UTF8Encoding]::new($false))
            Publish-DarktideCanonicalReport -AttemptReportPath $source -OutputPath $target -RunOwnedRoot $TestDrive | Should -BeExactly ([IO.Path]::GetFullPath($target))
            [IO.File]::ReadAllText($target,[Text.UTF8Encoding]::new($false)) | Should -BeExactly $case.Json
        }
        $existing=Join-Path $outputRoot 'existing.json'; [IO.File]::WriteAllText($existing,'sentinel',[Text.UTF8Encoding]::new($false))
        { Publish-DarktideCanonicalReport -AttemptReportPath (Join-Path $attemptRoot 'success.json') -OutputPath $existing -RunOwnedRoot $TestDrive } | Should -Throw
        [IO.File]::ReadAllText($existing,[Text.UTF8Encoding]::new($false)) | Should -BeExactly 'sentinel'
    }

    # Scenario: Stop-PlatformOwnedProcess returns a superficially successful but incomplete receipt.
    # Purpose: Cleanup uncertainty must never be accepted as successful child termination.
    It 'UnitT45_rejects_incomplete_owned_process_cleanup_receipts' {
        Test-DarktideOwnedProcessCleanupReceipt -Receipt ([pscustomobject]@{CleanedUp=$true}) | Should -BeFalse
        Test-DarktideOwnedProcessCleanupReceipt -Receipt ([pscustomobject]@{CleanedUp=$true;CaptureReadersStopped=$true;CaptureResourcesClosed=$true;RemainingPids=@(123);Uncertainty=$null}) | Should -BeFalse
        Test-DarktideOwnedProcessCleanupReceipt -Receipt ([pscustomobject]@{CleanedUp=$true;CaptureReadersStopped=$true;CaptureResourcesClosed=$true;RemainingPids=@();Uncertainty=$null}) | Should -BeTrue

        Mock -CommandName Stop-PlatformOwnedProcess -ModuleName $script:DriverModule.Name -MockWith {
            [pscustomobject]@{CleanedUp=$true;CaptureReadersStopped=$false;CaptureResourcesClosed=$true;RemainingPids=@();Uncertainty='reader status unavailable'}
        }
        Assert-TestThrowsLike {
            Invoke-DarktideOwnedProcess -ExecutablePath $script:PowerShellPath -Arguments @('-NoProfile','-NonInteractive','-Command','exit 0') `
                -WorkingDirectory $TestDrive -CaptureRoot $TestDrive
        } '*cleanup could not be verified*'
    }

    # Scenario: The protected driver starts a runner that does not exit before its own deadline.
    # Purpose: Make TimeoutSeconds supervise the process itself and require verified descendant cleanup.
    It 'UnitT46_bounds_and_cleans_up_a_hung_owned_process' {
        $module = $script:DriverModule
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Assert-TestThrowsLike {
            & $module {
                param($Executable, $CaptureRoot)
                Invoke-DarktideOwnedProcess -ExecutablePath $Executable `
                    -Arguments @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') `
                    -WorkingDirectory $CaptureRoot -CaptureRoot $CaptureRoot -TimeoutSeconds 1
            } $script:PowerShellPath $TestDrive
        } '*exceeded its 1 second deadline*'
        $stopwatch.Stop()
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
    }
}

Describe 'Darktide workflow leg helpers' {
    It 'UnitT50_verifies_protected_driver_helpers_against_the_event_base_blobs' {
        $root = Join-Path $TestDrive ('driver-' + [guid]::NewGuid().ToString('N'))
        New-TestGitRepository -Root $root
        foreach ($relative in Get-DarktideProtectedDriverHelperPaths) {
            $target = Join-Path $root $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.File]::WriteAllText($target, "content of $relative`n")
        }
        $base = Invoke-TestGitCommit -Root $root -Message 'driver'
        $legArgs = @{ DriverRoot=$root; BaseRevision=$base; GitPath=$script:GitPath; AuthorityRepositoryRoot=$script:AuthorityRoot; AuthorityRevision='fbdc793c1c439b15c6def97d53111f250d0ff4db'; CaptureRoot=$TestDrive }
        $bindings = @(Assert-DarktideProtectedDriverCheckout @legArgs)
        $bindings.Count | Should -Be @(Get-DarktideProtectedDriverHelperPaths).Count
        @($bindings | ForEach-Object { $_.path }) | Should -Contain 'scripts/StandardSourceDriver.psm1'
        $wrongHeadArgs = $legArgs.Clone(); $wrongHeadArgs.BaseRevision = '2' * 40
        Assert-TestThrowsLike { Assert-DarktideProtectedDriverCheckout @wrongHeadArgs } '*HEAD differs from the exact event base*'
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Validate.ps1'), "tampered`n")
        Assert-TestThrowsLike { Assert-DarktideProtectedDriverCheckout @legArgs } '*not clean*'
    }

    It 'UnitT51_lists_every_driver_file_the_workflow_executes' {
        $paths = @(Get-DarktideProtectedDriverHelperPaths)
        foreach ($relative in $paths) { Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $relative) -PathType Leaf | Should -BeTrue }
        foreach ($required in @('scripts/Validate.ps1', 'scripts/StandardSourceDriver.psm1', 'scripts/Invoke-SourceChild.ps1', 'scripts/Prepare-WorkflowPowerShell.ps1', 'scripts/Prepare-PesterRuntime.ps1', 'config/pester-6.2.0-closure.lock.json')) {
            $paths | Should -Contain $required
        }
    }

    It 'UnitT52_accepts_only_the_exact_successful_three_platform_receipt_set' {
        $root = Join-Path $TestDrive ('receipts-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $outcomes = [ordered]@{}
        foreach ($name in Get-DarktideLegOutcomeNames) { $outcomes[$name] = 'success' }
        $common = @{
            RunId = '42'; RunAttempt = '1'; EventName = 'pull_request'; CandidateSha = ('c' * 40); BaseSha = ('b' * 40)
            AuthoritySha = 'fbdc793c1c439b15c6def97d53111f250d0ff4db'; PythonVersion = '3.12.9'; PowerShellVersion = '7.5.4'
            PowerShellArchiveSha256 = ('f' * 64); SourceReportSha256 = ('e' * 64); SetupSeconds = 10; SourceValidationSeconds = 20; TotalSeconds = 30
        }
        $platforms = @(
            @{ Platform = 'windows'; Os = 'windows-latest'; Architecture = 'x64'; RunnerOs = 'Windows' }
            @{ Platform = 'linux'; Os = 'ubuntu-latest'; Architecture = 'x64'; RunnerOs = 'Linux' }
            @{ Platform = 'macos'; Os = 'macos-latest'; Architecture = 'arm64'; RunnerOs = 'macOS' }
        )
        $paths = @(foreach ($platform in $platforms) {
            $leg = $common + $platform
            New-DarktidePlatformLegReceipt -Path (Join-Path $root "leg-$($platform.Platform).json") -Outcomes $outcomes @leg
        })
        $expected = @{ MatrixResult = 'success'; RunId = '42'; RunAttempt = '1'; EventName = 'pull_request'; CandidateSha = ('c' * 40); BaseSha = ('b' * 40); AuthoritySha = 'fbdc793c1c439b15c6def97d53111f250d0ff4db' }
        @(Test-DarktidePlatformLegReceiptSet -ReceiptPaths $paths @expected).Count | Should -Be 0
        @(Test-DarktidePlatformLegReceiptSet -ReceiptPaths @($paths | Select-Object -First 2) @expected) | Should -Contain "Platform 'macos' must have exactly one receipt; found 0."
        $failedOutcomes = [ordered]@{}
        foreach ($name in Get-DarktideLegOutcomeNames) { $failedOutcomes[$name] = if ($name -ceq 'sourceValidation') { 'failure' } else { 'success' } }
        $failedLeg = $common + $platforms[1]
        $failedPath = New-DarktidePlatformLegReceipt -Path (Join-Path $root 'leg-linux-failed.json') -Outcomes $failedOutcomes @failedLeg
        @(Test-DarktidePlatformLegReceiptSet -ReceiptPaths @($paths[0], $failedPath, $paths[2]) @expected) | Should -Contain "linux protected step 'sourceValidation' outcome is 'failure'."
        $wrongAuthority = $expected.Clone(); $wrongAuthority.AuthoritySha = 'ead467c3488c103546f316d137196b447a1ff58a'
        @(Test-DarktidePlatformLegReceiptSet -ReceiptPaths $paths @wrongAuthority).Count | Should -Be 3
        $matrixFailed = $expected.Clone(); $matrixFailed.MatrixResult = 'failure'
        @(Test-DarktidePlatformLegReceiptSet -ReceiptPaths $paths @matrixFailed) | Should -Contain "canonical-validation matrix result is 'failure', expected 'success'."
        $reordered = [ordered]@{}
        foreach ($name in @(Get-DarktideLegOutcomeNames | Sort-Object)) { $reordered[$name] = 'success' }
        Assert-TestThrowsLike { New-DarktidePlatformLegReceipt -Path (Join-Path $root 'bad.json') -Outcomes $reordered @failedLeg } '*incomplete or reordered*'
        { New-DarktidePlatformLegReceipt -Path $paths[0] -Outcomes $outcomes @failedLeg } | Should -Throw
    }
}
