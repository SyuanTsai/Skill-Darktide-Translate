# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:DriverPath = Join-Path $script:RepositoryRoot 'scripts/StandardSourceDriver.psm1'
    $script:LegPath = Join-Path $script:RepositoryRoot 'scripts/StandardWorkflowLeg.psm1'
    $script:ValidatePath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
    $script:ChildPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceChild.ps1'
    $script:PowerShellPath = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    Import-Module -Name $script:DriverPath -Force
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

    It 'UnitT13_executes_the_v2_route_on_this_host_and_fails_closed_on_the_active_v1_pin' {
        $artifacts = Join-Path $TestDrive ('artifacts-' + [guid]::NewGuid().ToString('N'))
        $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $script:ValidatePath -AdapterVersion 2 -PrepareSourceTools `
            -SourceToolsPath (Join-Path $artifacts 'source-tools.json') -AuthorityRepositoryRoot $TestDrive -TrustedToolRoot $TestDrive -ArtifactsRoot $artifacts 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -BeLike '*Prepared source authority commit does not match the exact approved tuple*'
        ($output -join "`n") | Should -Not -BeLike '*requires Windows*'
        Test-Path -LiteralPath $artifacts | Should -BeFalse
    }

    It 'UnitT14_rejects_v2_parameters_without_a_source_purpose_through_Validate' {
        $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $script:ValidatePath -AdapterVersion 2 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -BeLike '*only valid with -AdapterVersion 2 and an explicit source purpose*'
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
}

Describe 'Darktide Core v2 adapter, dispatch and protected readers' {
    It 'UnitT20_builds_the_exact_standard_core_adapter_v2' {
        $sourceValidation = [ordered]@{ marker = 'kept' }
        $adapter = New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @('auto-update-darktide-mod') -SourceValidation $sourceValidation
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
        @($adapter.checks[1].arguments) | Should -Be @('-NoProfile', '-NonInteractive', '-File', 'scripts/Invoke-CorePester.ps1')
        foreach ($check in $adapter.checks) {
            $check.executable | Should -BeExactly $script:PowerShellPath
            $check.executableSha256 | Should -BeExactly (Get-FileHash -LiteralPath $script:PowerShellPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $adapter.sourceValidation.marker | Should -BeExactly 'kept'
        Assert-TestThrowsLike { New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @() -SourceValidation $sourceValidation } '*at least one active Skill*'
        Assert-TestThrowsLike { New-DarktideSourceCoreAdapter -PowerShell $script:PowerShellPath -ActiveSkillIds @('Bad_Id') -SourceValidation $sourceValidation } '*invalid Skill ID*'
    }

    It 'UnitT21_dispatches_each_slot_to_one_child_mode' {
        $arguments = Get-DarktideSourceDispatchArguments -ChildPath 'C' -ToolchainPath 'T' -ToolchainSha256 ('b' * 64)
        @($arguments.Keys) | Should -Be @('packageAdapter', 'skillValidator', 'skillTools', 'staticAnalyzer')
        $modes = @{ packageAdapter = 'package-adapter'; skillValidator = 'skill-validator'; skillTools = 'skill-tools'; staticAnalyzer = 'static' }
        foreach ($slot in $modes.Keys) {
            @($arguments[$slot]) | Should -Be @('-NoProfile', '-NonInteractive', '-File', 'C', '-ToolchainPath', 'T', '-ToolchainSha256', ('b' * 64), '-Mode', $modes[$slot])
        }
    }

    It 'UnitT22_child_runner_exposes_only_the_four_source_modes_without_semantic_escalation' {
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

    It 'UnitT23_requires_candidate_protected_readers_to_equal_the_driver_bytes' {
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

    It 'UnitT24_protected_readers_of_this_checkout_are_self_consistent' {
        @(Assert-DarktideSourceProtectedReaders -ProtectedBaseRoot $script:RepositoryRoot -CandidateRoot $script:RepositoryRoot).Count | Should -Be 4
        (Get-DarktideSourceChildRunnerPath) | Should -BeExactly ([IO.Path]::GetFullPath($script:ChildPath))
    }

    It 'UnitT25_reads_the_strict_active_skill_inventory' {
        @(Get-DarktideActiveSkillIds -Root $script:RepositoryRoot) | Should -Be @('auto-update-darktide-mod')
        $fixture = Join-Path $TestDrive ('inventory-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $fixture 'catalog'), (Join-Path $fixture 'skills/auto-update-darktide-mod'), (Join-Path $fixture 'skills/extra-skill') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog/source.json') -Destination (Join-Path $fixture 'catalog/source.json')
        Assert-TestThrowsLike { Get-DarktideActiveSkillIds -Root $fixture } '*does not exactly match skills/ directories*'
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
        $bindings = @(Assert-DarktideProtectedDriverCheckout -DriverRoot $root -BaseRevision $base -GitPath $script:GitPath)
        $bindings.Count | Should -Be @(Get-DarktideProtectedDriverHelperPaths).Count
        @($bindings | ForEach-Object { $_.path }) | Should -Contain 'scripts/StandardSourceDriver.psm1'
        Assert-TestThrowsLike { Assert-DarktideProtectedDriverCheckout -DriverRoot $root -BaseRevision ('2' * 40) -GitPath $script:GitPath } '*HEAD differs from the exact event base*'
        [IO.File]::WriteAllText((Join-Path $root 'scripts/Validate.ps1'), "tampered`n")
        Assert-TestThrowsLike { Assert-DarktideProtectedDriverCheckout -DriverRoot $root -BaseRevision $base -GitPath $script:GitPath } '*not clean*'
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
