# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:ChildPath = Join-Path $script:RepositoryRoot 'scripts/Invoke-SourceChild.ps1'
    $script:DriverPath = Join-Path $script:RepositoryRoot 'scripts/StandardSourceDriver.psm1'
    $script:PowerShellPath = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $script:AuthorityRoot = [Environment]::GetEnvironmentVariable('DT_TEST_AUTHORITY_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($script:AuthorityRoot)) {
        $script:AuthorityRoot = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '../mainbase'))
    }
    $script:AuthorityRevision = 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
    $manifest = Join-Path $script:AuthorityRoot 'scripts/platform-runtime.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'd3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9') {
        $sourceRepository = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '../mainbase'))
        $archive = Join-Path $TestDrive 'authority-fbdc793.zip'
        $script:AuthorityRoot = Join-Path $TestDrive 'authority-fbdc793'
        & git -C $sourceRepository archive --format=zip --output=$archive $script:AuthorityRevision
        if ($LASTEXITCODE -ne 0) { throw 'Could not materialize the offline authority fixture.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $script:AuthorityRoot
    }
    $script:DriverSha256 = (Get-FileHash -LiteralPath $script:DriverPath -Algorithm SHA256).Hash.ToLowerInvariant()

    function Set-SourceChildEnvironment {
        param([string] $CandidateRoot, [string] $SkillRoot, [string] $Scenario)
        $env:STANDARD_VALIDATION_CANDIDATE_ROOT = $CandidateRoot
        $env:STANDARD_VALIDATION_SKILLS_ROOT = Split-Path -Parent $SkillRoot
        $env:STANDARD_VALIDATION_ACTIVE_SKILLS = 'auto-update-darktide-mod'
        $env:STANDARD_VALIDATION_SKILL_ID = 'auto-update-darktide-mod'
        $env:STANDARD_VALIDATION_CANDIDATE_ID = 'candidate-fixture-identity'
        $env:STANDARD_VALIDATION_SKILL_INVENTORY_SHA256 = 'a' * 64
        $env:SOURCE_CHILD_FIXTURE_SCENARIO = $Scenario
    }

    function New-SourceChildFixture {
        param([Parameter(Mandatory)][string] $Root)
        $candidate = Join-Path $Root 'candidate'
        $skillRoot = Join-Path $candidate 'skills/auto-update-darktide-mod'
        New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $skillRoot 'SKILL.md'), "---`nname: auto-update-darktide-mod`ndescription: fixture`n---`n")
        $tool = Join-Path $Root 'fixture-tool.ps1'
        $toolSource = @'
$Rest = [string[]]$args
$scenario = [string]$env:SOURCE_CHILD_FIXTURE_SCENARIO
if ($scenario -ceq 'nonzero') { [Console]::Error.WriteLine('fixture non-zero'); exit 9 }
if ($scenario -ceq 'malformed') { [Console]::Out.WriteLine('{'); return }
if ($scenario -ceq 'hang') { [Console]::Error.WriteLine('fixture hang evidence'); Start-Sleep -Seconds 30; return }
if ($scenario -ceq 'descendant') {
    $child = Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -PassThru
    [Console]::Error.WriteLine("fixture descendant evidence pid=$($child.Id)")
    Start-Sleep -Seconds 30
    return
}
$skillId = 'auto-update-darktide-mod'
$skillRoot = Join-Path ([string]$env:STANDARD_VALIDATION_SKILLS_ROOT) $skillId
$skillFile = Join-Path $skillRoot 'SKILL.md'
if ($Rest -contains 'scan') {
    [object[]]$issues = @()
    if ($scenario -ceq 'blocking') { $issues = @([ordered]@{severity='high';rule_id='fixture-static';message='blocking';file=$skillFile}) }
    $report = [ordered]@{
        execution_successful=$true
        analysis_completeness=[ordered]@{execution_successful=$true;is_complete=$true;status='complete';coverage_percent=100;ledger_exceptions=@();scope_exclusions=@();limitations=@()}
        skill=[ordered]@{name=$skillId;source=$skillRoot}
        components=@([ordered]@{path='SKILL.md'})
        issues=$issues
    }
}
elseif ($Rest -contains 'sarif') {
    $rules=@(); $results=@()
    if ($scenario -ceq 'blocking') {
        $rules=@([ordered]@{id='fixture-warning';defaultConfiguration=[ordered]@{level='warning'}})
        $results=@([ordered]@{ruleId='fixture-warning';level='warning';message=[ordered]@{text='blocking'};locations=@([ordered]@{physicalLocation=[ordered]@{artifactLocation=[ordered]@{uri=$skillFile}}})})
    }
    $report=[ordered]@{version='2.1.0';runs=@([ordered]@{tool=[ordered]@{driver=[ordered]@{name='skill-tools';rules=$rules}};results=$results})}
}
elseif ($Rest -contains 'route') {
    $report=@([ordered]@{skill=$skillId})
}
else {
    $blocked = $scenario -ceq 'blocking'
    $report=[ordered]@{skill_dir=$skillRoot;passed=(-not $blocked);errors=$(if($blocked){1}else{0});warnings=0;results=@([ordered]@{level=$(if($blocked){'error'}else{'pass'});category='fixture';message='fixture';file=$skillFile})}
}
[Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 20 -Compress))
'@
        [IO.File]::WriteAllText($tool, $toolSource, [Text.UTF8Encoding]::new($false))
        $entryPoint = Join-Path $Root 'fixture-entry.ps1'
        [IO.File]::WriteAllText($entryPoint, '# fixture entry point', [Text.UTF8Encoding]::new($false))
        $runner = Join-Path $script:AuthorityRoot 'scripts/Invoke-StandardValidation.ps1'
        $toolchain = [ordered]@{
            centralRunnerPath=$runner; centralRunnerSha256=(Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash.ToLowerInvariant()
            skillValidatorPath=$tool; skillValidatorSha256=(Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant()
            skillToolsNodePath=$tool; skillToolsNodeSha256=(Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant()
            skillToolsEntryPointPath=$entryPoint; skillToolsEntryPointSha256=(Get-FileHash -LiteralPath $entryPoint -Algorithm SHA256).Hash.ToLowerInvariant()
            skillSpectorPath=$tool; skillSpectorSha256=(Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash.ToLowerInvariant()
            skillSpectorReceiptPath=$entryPoint; skillSpectorReceiptSha256=(Get-FileHash -LiteralPath $entryPoint -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $toolchainPath = Join-Path $Root 'toolchain.json'
        [IO.File]::WriteAllText($toolchainPath, (($toolchain | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ Candidate=$candidate; SkillRoot=$skillRoot; Toolchain=$toolchainPath; ToolchainSha256=(Get-FileHash -LiteralPath $toolchainPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    }

    function Invoke-SourceChildFixture {
        param([string] $Mode, [string] $Scenario, [int] $TimeoutSeconds = 900)
        $root = Join-Path $TestDrive ("$Mode-$Scenario-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $fixture = New-SourceChildFixture -Root $root
        Set-SourceChildEnvironment -CandidateRoot $fixture.Candidate -SkillRoot $fixture.SkillRoot -Scenario $Scenario
        Push-Location $root
        try {
            $output = @(& $script:PowerShellPath -NoProfile -NonInteractive -File $script:ChildPath -Mode $Mode `
                -ToolchainPath $fixture.Toolchain -ToolchainSha256 $fixture.ToolchainSha256 `
                -DriverModulePath $script:DriverPath -DriverModuleSha256 $script:DriverSha256 `
                -AuthorityRuntimeManifestPath (Join-Path $script:AuthorityRoot 'scripts/platform-runtime.psd1') -AuthorityRevision $script:AuthorityRevision `
                -TimeoutSeconds $TimeoutSeconds 2>&1)
            return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($output -join "`n"); Root=$root }
        }
        finally { Pop-Location }
    }
}

Describe 'Protected Core v2 source child subprocess behavior' {
    # Scenario: Each of the four source slots receives valid candidate-bound fixture output.
    # Purpose: Exercise the real child process and preserve its envelope, native-report, and candidate identity contracts.
    It 'InterT10_executes_<Mode>_success_with_candidate_bound_evidence' -ForEach @(
        @{Mode='package-adapter'}, @{Mode='skill-validator'}, @{Mode='skill-tools'}, @{Mode='static'}
    ) {
        $result = Invoke-SourceChildFixture -Mode $Mode -Scenario success
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $envelope = $result.Output | ConvertFrom-Json -Depth 100
        $envelope.candidateIdentity | Should -BeExactly 'candidate-fixture-identity'
        @($envelope.activeSkills) | Should -Be @('auto-update-darktide-mod')
        if ($Mode -in @('skill-validator','skill-tools','static')) {
            @($envelope.nativeReports).Count | Should -Be 1
            $envelope.nativeReports[0].commandSha256 | Should -MatchExactly '^[0-9a-f]{64}$'
            $envelope.nativeReports[0].sha256 | Should -MatchExactly '^[0-9a-f]{64}$'
        }
        if ($Mode -in @('skill-validator','skill-tools')) { $envelope.skillInventorySha256 | Should -BeExactly ('a' * 64) }
    }

    # Scenario: Every source slot's fixture exits non-zero before producing a complete report.
    # Purpose: Prevent any mode from converting native tool failure into a successful envelope.
    It 'InterT20_rejects_<Mode>_native_nonzero_exit' -ForEach @(
        @{Mode='package-adapter'}, @{Mode='skill-validator'}, @{Mode='skill-tools'}, @{Mode='static'}
    ) {
        (Invoke-SourceChildFixture -Mode $Mode -Scenario nonzero).ExitCode | Should -Not -Be 0
    }

    # Scenario: Every source slot receives malformed JSON from its fixture executable.
    # Purpose: Require complete parseable reports instead of accepting partial native output.
    It 'InterT30_rejects_<Mode>_malformed_or_incomplete_report' -ForEach @(
        @{Mode='package-adapter'}, @{Mode='skill-validator'}, @{Mode='skill-tools'}, @{Mode='static'}
    ) {
        (Invoke-SourceChildFixture -Mode $Mode -Scenario malformed).ExitCode | Should -Not -Be 0
    }

    # Scenario: Validator and SARIF fixtures emit blocking evidence while Static emits a high finding for the central gate.
    # Purpose: Preserve warning/error blocking and carry Static findings forward without silently dropping them.
    It 'InterT40_preserves_<Mode>_blocking_finding_semantics' -ForEach @(
        @{Mode='package-adapter';ChildFails=$true}, @{Mode='skill-validator';ChildFails=$true},
        @{Mode='skill-tools';ChildFails=$true}, @{Mode='static';ChildFails=$false}
    ) {
        $result = Invoke-SourceChildFixture -Mode $Mode -Scenario blocking
        if ($ChildFails) { $result.ExitCode | Should -Not -Be 0 }
        else {
            $result.ExitCode | Should -Be 0 -Because $result.Output
            $envelope = $result.Output | ConvertFrom-Json -Depth 100
            @($envelope.findings).Count | Should -Be 1
            $envelope.findings[0].severity | Should -BeExactly 'high'
        }
    }

    # Scenario: A native source tool hangs directly or leaves a sleeping descendant past a one-second deadline.
    # Purpose: Bound failure time, reject success envelopes, and retain capture evidence for cleanup diagnosis.
    It 'InterT50_times_out_<Scenario>_and_retains_failure_evidence' -ForEach @(
        @{Scenario='hang'}, @{Scenario='descendant'}
    ) {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $result=Invoke-SourceChildFixture -Mode skill-validator -Scenario $Scenario -TimeoutSeconds 1
        $watch.Stop()
        $result.ExitCode | Should -Not -Be 0
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
        $result.Output | Should -Not -Match '"validation":"skill-validator"'
        $captures=@(Get-ChildItem -LiteralPath $result.Root -File | Where-Object Name -Match '\.(stdout|stderr)$')
        $captures.Count | Should -BeGreaterThan 0
        $captureText=@($captures | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $captureText | Should -Match 'fixture (hang|descendant) evidence'
        if($Scenario -ceq 'descendant') {
            $pidMatch=[regex]::Match($captureText,'pid=(?<pid>[0-9]+)')
            $pidMatch.Success | Should -BeTrue
            Get-Process -Id ([int]$pidMatch.Groups['pid'].Value) -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}
