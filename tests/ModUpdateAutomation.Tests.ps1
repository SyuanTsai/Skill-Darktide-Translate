Describe 'Deterministic Darktide MOD update automation' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $skillRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod'
        $runnerPath = Join-Path $skillRoot 'scripts/mod-update.ps1'
        $validatorPath = Join-Path $skillRoot 'scripts/Test-ModUpdateCandidate.ps1'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:skillSourcePinPath = New-TestSkillSourcePin -SkillRoot $skillRoot -OutputPath (Join-Path $TestDrive 'skill-source-pin.json')
    }

    # Scenario: An agent selects the Skill for an archive-backed MOD update or recovery.
    # Purpose: Keep one fixed runner, an independent validator, and only the required progressive-disclosure reference discoverable.
    It 'UnitT100_PublishesTheRunnerValidatorAndAutomationReference' {
        Test-Path -LiteralPath $runnerPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath $validatorPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $skillRoot 'references/automation.md') -PathType Leaf | Should -Be $true
        foreach ($script in @('Receive-NexusMainFile.ps1', 'Test-SourceReceipt.ps1', 'Invoke-ModUpdateQueue.ps1', 'SharedCoordinationLock.psm1', 'New-LocalizationWorkset.ps1', 'Apply-LocalizationWorkset.ps1')) {
            Test-Path -LiteralPath (Join-Path (Join-Path $skillRoot 'scripts') $script) -PathType Leaf | Should -Be $true
        }

        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
        $skill | Should -Match 'scripts/mod-update\.ps1'
        $skill | Should -Match 'scripts/Test-ModUpdateCandidate\.ps1'
        $skill | Should -Match 'references/automation\.md'
    }

    # Scenario: The fixed automation package is loaded into a PowerShell session that relies on built-in automatic variables.
    # Purpose: Prevent local assignments from shadowing PowerShell's pipeline-input and regex-match automatic variables.
    It 'UnitT105_AvoidsAssignmentsToInputAndMatchesAutomaticVariables' {
        $scriptFiles = Get-ChildItem -LiteralPath (Join-Path $skillRoot 'scripts') -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') }

        foreach ($scriptFile in $scriptFiles) {
            $scriptContent = Get-Content -LiteralPath $scriptFile.FullName -Raw
            $scriptContent | Should -Not -Match '(?im)^\s*\$(?:input|matches)\s*=' -Because $scriptFile.Name
        }
    }

    # Scenario: A caller invokes a single stage or resumes the same run.
    # Purpose: Preserve the fixed command surface, structured JSON, timing, state, and idempotency contracts.
    It 'UnitT110_DeclaresTheFixedResumableStageContract' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($stage in @('acquire-source', 'claim', 'verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot', 'run')) {
            $runner | Should -Match ([regex]::Escape("'$stage'"))
        }

        $runner | Should -Match 'state\.json'
        $runner | Should -Match 'stageTimings'
        $runner | Should -Match 'activeMilliseconds'
        $runner | Should -Match 'waitingMilliseconds'
        $runner | Should -Match 'artifactSha256'
        $runner | Should -Match 'ConvertTo-Json'
    }

    # Scenario: A stage spends controlled monotonic-clock intervals on source stability, coordination, and active work.
    # Purpose: Keep audited wall time equal to active plus classified waits without mixing stability and lock contention.
    It 'UnitT115_SeparatesActiveStabilityAndCoordinationTiming' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $allFunctions = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
        $functionTexts = foreach ($name in @(
            'Get-UtcTimestamp', 'Start-Stage', 'Add-StageWait', 'Get-StageTimingBreakdown', 'Enter-SharedCoordinationLock'
        )) {
            $functionAst = @($allFunctions | Where-Object Name -eq $name)[0]
            $functionAst | Should -Not -BeNullOrEmpty
            $functionAst.Extent.Text
        }
        $coordinationStub = @'
function Update-ActiveReservationHeartbeat {}
function Enter-SharedCoordinationLease {
    param($RepositoryRoot, $ResourceKey, $RunId, $ReceiptRoot, $WaitHeartbeatAction, $TimeoutSeconds)
    [ordered]@{ waitingMilliseconds = [int64]25 }
}
'@
        $module = New-Module -ScriptBlock ([scriptblock]::Create((@($coordinationStub) + $functionTexts -join "`n")))
        try {
            $clockValue = [Runtime.CompilerServices.StrongBox[long]]::new(1000)
            $clock = { [int64]$clockValue.Value }.GetNewClosure()
            $context = & $module { param($clock) Start-Stage -Name 'claim' -MonotonicClock $clock } $clock
            $clockValue.Value = [int64]1100
            & $module { param($context) Add-StageWait -Context $context -Reason 'stability-observation' -Milliseconds 75 } $context
            $clockValue.Value = [int64]1150
            $lease = & $module {
                Enter-SharedCoordinationLock -Repository 'C:\timing-test' -ResourceKey 'source-acquisition' -ActualRunId 'timing-test'
            }
            $lease.waitingMilliseconds | Should -Be 25
            $clockValue.Value = [int64]1200
            $timing = & $module { param($context) Get-StageTimingBreakdown -Context $context } $context

            $timing.wallClockMilliseconds | Should -Be 200
            $timing.activeMilliseconds | Should -Be 100
            $timing.waitingMilliseconds | Should -Be 100
            $timing.stabilityObservationMilliseconds | Should -Be 75
            $timing.coordinationWaitMilliseconds | Should -Be 25
            ([int64]$timing.activeMilliseconds + [int64]$timing.waitingMilliseconds) |
                Should -Be ([int64]$timing.wallClockMilliseconds)
        }
        finally {
            Remove-Module $module -Force
        }
    }

    # Scenario: A supplied ZIP contains line-ending variants, whitespace-sensitive Lua, or a hostile path.
    # Purpose: Require archive containment checks and byte-preserving extraction without trim, formatter, or cross-line replacement behavior.
    It 'UnitT120_ImplementsContainedBytePreservingArchiveExtraction' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Match 'ZipArchive'
        $runner | Should -Match 'GetFullPath'
        $runner | Should -Match 'StartsWith'
        $runner | Should -Match 'ExternalAttributes'
        $runner | Should -Match 'CreateNew'
        $runner | Should -Match 'ExpectedSha256'
        $runner | Should -Match 'function Get-FileSha256'
        $runner | Should -Match 'Copy-StreamWithHeartbeat'
        $runner | Should -Match 'Source archive must be a regular file, not a reparse point'
        $runner | Should -Match 'Claimed archive must be a regular file, not a reparse point'
        $runner | Should -Match '\$entryStream\s*=\s*\$entry\.Open\(\)'
        $runner | Should -Not -Match '\$input\s*='
        $runner | Should -Not -Match '(?i)Invoke-Expression|\biex\b'
        $runner | Should -Not -Match '(?i)(Get-Content|ReadAllText|ReadAllBytes)[^\r\n]*Trim(?:End)?\(|-replace\s+[''\"]\\s'
    }

    # Scenario: Direct localization fields or dynamic lookups need approved Traditional Chinese maintenance.
    # Purpose: Keep semantic selection outside the script and permit only explicit byte-span replacements over an immutable indexed base.
    It 'UnitT130_AppliesOnlyApprovedLocalizationByteSpans' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        $runner | Should -Match 'replacementBase64'
        $runner | Should -Match 'startByte'
        $runner | Should -Match 'oldSha256'
        $runner | Should -Match 'indexedSha256'
        $validator | Should -Match 'approvedSpans'
        $validator | Should -Match 'outside approved localization spans'
        $validator | Should -Not -Match 'ModUpdate\.Automation\.psm1'
    }

    # Scenario: A Schema 14 MOD has no active localization and the caller omits a localization plan.
    # Purpose: Keep the default none-mode path array-shaped under StrictMode so an empty removed-path set can complete normally.
    It 'UnitT135_CompletesSchema14LocalizationWithoutAPlan' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Localization'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $stubs = @'
Set-StrictMode -Version Latest
$script:LocalizationPlanPath = $null
function Get-CompletedStageResult { param($State, $Name) $null }
function Start-Stage { param($Name) [ordered]@{ name = $Name } }
function Assert-LockOwner { param($State) }
function Assert-NoReparseTree { param($Path, $Root, $Label) $Path }
function Assert-NoReparsePath { param($Path, $Root, $Label) $Path }
function Read-FileBytesWithHeartbeat { param($Path) [IO.File]::ReadAllBytes($Path) }
function Write-AtomicJson { param($Path, $Value) }
function Get-FileSha256 { param($Path) 'a' * 64 }
function Get-Sha256Bytes { param($Bytes) 'b' * 64 }
function Complete-Stage {
    param($State, $Context, $ArtifactSha256, $Data)
    [pscustomobject]@{ result = 'passed'; status = $State.status; data = $Data }
}
'@
        $module = New-Module -ScriptBlock ([scriptblock]::Create($stubs + "`n" + $functionAst.Extent.Text))
        try {
            $installRoot = Join-Path $TestDrive 'schema14-none-install'
            New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
            $state = [ordered]@{
                schemaVersion = 14
                installRoot = $installRoot
                rawInstallManifest = [ordered]@{ sha256 = 'c' * 64 }
                metadataPaths = @('README.md', '.hash/example.hash')
                artifactsRoot = Join-Path $TestDrive 'schema14-none-artifacts'
                modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
                worktreePath = $TestDrive
                evidenceChain = [ordered]@{ c0Oid = '1' * 40 }
            }

            $result = & $module { param($value) Invoke-Localization -State $value } $state

            $result.result | Should -Be 'passed'
            $result.data.mode | Should -Be 'none'
            $result.data.fileCount | Should -Be 0
            $state.status | Should -Be 'localized'
            @($state.localizationRemovedPaths).Count | Should -Be 0
            @($state.evidenceTargetPaths).Count | Should -Be 0
        }
        finally {
            Remove-Module $module -Force
        }
    }

    # Scenario: A Schema 14 MOD descriptor mentions mod_localization only inside Lua comments and quoted strings.
    # Purpose: Preserve no-plan mode=none compatibility when executable descriptor fields do not register localization.
    It 'UnitT136_IgnoresNonCodeSchema14LocalizationMentions' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Localization'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $stubs = @'
Set-StrictMode -Version Latest
$script:LocalizationPlanPath = $null
function Get-CompletedStageResult { param($State, $Name) $null }
function Start-Stage { param($Name) [ordered]@{ name = $Name } }
function Assert-LockOwner { param($State) }
function Assert-NoReparseTree { param($Path, $Root, $Label) $Path }
function Assert-NoReparsePath { param($Path, $Root, $Label) $Path }
function Read-FileBytesWithHeartbeat { param($Path) [IO.File]::ReadAllBytes($Path) }
function Write-AtomicJson { param($Path, $Value) }
function Get-FileSha256 { param($Path) 'a' * 64 }
function Get-Sha256Bytes { param($Bytes) 'b' * 64 }
function Complete-Stage {
    param($State, $Context, $ArtifactSha256, $Data)
    [pscustomobject]@{ result = 'passed'; status = $State.status; stage = 'localization'; data = $Data }
}
function Suspend-Stage {
    param($State, $Context, $Result, $ArtifactSha256, $OutputStage, $Data)
    [pscustomobject]@{ result = $Result; status = $State.status; stage = $OutputStage; data = $Data }
}
'@
        Import-Module (Join-Path (Join-Path $skillRoot 'scripts') 'LuaLocalizationScanner.psm1') -Force
        $module = New-Module -ScriptBlock ([scriptblock]::Create($stubs + "`n" + $functionAst.Extent.Text))
        try {
            $installRoot = Join-Path $TestDrive 'schema14-non-code-localization'
            New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
            [IO.File]::WriteAllText(
                (Join-Path $installRoot 'ExampleMod.mod'),
                "-- mod_localization = `"comment-only`"`nlocal note = `"mod_localization = 'string-only'`"`nreturn { enabled = true }",
                [Text.UTF8Encoding]::new($false)
            )
            $state = [ordered]@{
                schemaVersion = 14
                installRoot = $installRoot
                worktreePath = $TestDrive
                rawInstallManifest = [ordered]@{ sha256 = 'c' * 64 }
                metadataPaths = @('README.md', '.hash/example.hash')
                artifactsRoot = Join-Path $TestDrive 'schema14-non-code-artifacts'
                modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
                evidenceChain = [ordered]@{ c0Oid = '1' * 40 }
            }

            $result = & $module { param($value) Invoke-Localization -State $value } $state

            $result.result | Should -Be 'passed'
            $result.data.mode | Should -Be 'none'
            $state.status | Should -Be 'localized'
        }
        finally {
            Remove-Module $module -Force
        }
    }

    # Scenario: A Schema 14 MOD descriptor registers mod_localization, first suspends without a plan, then resumes with an explicit mode=none plan.
    # Purpose: Detect equivalent Lua table fields and clear the resolved localization-plan waiting reason after the same state resumes successfully.
    It 'UnitT137_SuspendsAndResumesSchema14LocalizationWithAnExplicitPlan' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Localization'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $stubs = @'
Set-StrictMode -Version Latest
$script:LocalizationPlanPath = $null
function Get-CompletedStageResult { param($State, $Name) $null }
function Start-Stage { param($Name) [ordered]@{ name = $Name } }
function Assert-LockOwner { param($State) }
function Assert-NoReparseTree { param($Path, $Root, $Label) $Path }
function Assert-NoReparsePath { param($Path, $Root, $Label) $Path }
function Read-FileBytesWithHeartbeat { param($Path) [IO.File]::ReadAllBytes($Path) }
function Write-AtomicJson { param($Path, $Value) }
function Get-FileSha256 { param($Path) 'a' * 64 }
function Get-Sha256Bytes { param($Bytes) 'b' * 64 }
function Complete-Stage {
    param($State, $Context, $ArtifactSha256, $Data)
    [pscustomobject]@{ result = 'passed'; status = $State.status; stage = 'localization'; data = $Data }
}
function Suspend-Stage {
    param($State, $Context, $Result, $ArtifactSha256, $OutputStage, $Data)
    [pscustomobject]@{ result = $Result; status = $State.status; stage = $OutputStage; data = $Data }
}
'@
        Import-Module (Join-Path (Join-Path $skillRoot 'scripts') 'LuaLocalizationScanner.psm1') -Force
        $module = New-Module -ScriptBlock ([scriptblock]::Create($stubs + "`n" + $functionAst.Extent.Text))
        try {
            $planPath = Join-Path $TestDrive 'schema14-explicit-none-plan.json'
            [ordered]@{ schemaVersion = 1; mode = 'none'; files = @(); removedPaths = @() } |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -NoNewline
            $descriptors = @(
                'return { run = function() new_mod("ExampleMod", { mod_localization = "ExampleMod/ExampleMod_localization" }) end }',
                "return { run = function() new_mod(`"ExampleMod`", { mod_localization`n=`n`"ExampleMod/ExampleMod_localization`" }) end }",
                'return { run = function() new_mod("ExampleMod", { ["mod_localization"] = "ExampleMod/ExampleMod_localization" }) end }'
            )
            for ($index = 0; $index -lt $descriptors.Count; $index++) {
                $installRoot = Join-Path $TestDrive "schema14-registered-localization-$index"
                New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
                [IO.File]::WriteAllText(
                    (Join-Path $installRoot 'ExampleMod.mod'),
                    $descriptors[$index],
                    [Text.UTF8Encoding]::new($false)
                )
                $state = [ordered]@{
                    schemaVersion = 14
                    installRoot = $installRoot
                    worktreePath = $TestDrive
                    rawInstallManifest = [ordered]@{ sha256 = 'c' * 64 }
                    metadataPaths = @('README.md', '.hash/example.hash')
                    artifactsRoot = Join-Path $TestDrive "schema14-registered-artifacts-$index"
                    modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
                    evidenceChain = [ordered]@{ c0Oid = '1' * 40 }
                }

                & $module { $script:LocalizationPlanPath = $null }
                $result = & $module { param($value) Invoke-Localization -State $value } $state

                $result.result | Should -Be 'waiting-input'
                $result.stage | Should -Be 'localization-plan'
                $result.data.code | Should -Be 'localization_plan_required'
                @($result.data.registeredModFiles) | Should -Be @('ExampleMod.mod')
                $state.status | Should -Be 'waiting-input'
                $state.waitingReason.code | Should -Be 'localization_plan_required'
                $state.Contains('localizationMode') | Should -BeFalse

                & $module { param($path) $script:LocalizationPlanPath = $path } $planPath
                $resumed = & $module { param($value) Invoke-Localization -State $value } $state

                $resumed.result | Should -Be 'passed'
                $state.status | Should -Be 'localized'
                $state.waitingReason | Should -BeNullOrEmpty
            }
        }
        finally {
            Remove-Module $module -Force
        }
    }

    # Scenario: Evidence is built for localization and non-localization runs, including a repair after publication.
    # Purpose: Preserve C0/C1/C2/C3/F identities, parent-tree invariants, normal Git index rules, and append-only history.
    It 'UnitT140_EnforcesLayeredGitEvidenceAndAppendOnlyPublication' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        foreach ($checkpoint in @('c0Oid', 'c1Oid', 'c2Oid', 'c3Oid', 'fOid')) {
            $runner | Should -Match $checkpoint
            $validator | Should -Match $checkpoint
        }
        $runner | Should -Match 'core\.autocrlf=true'
        $runner | Should -Match 'function Assert-AppendOnlyPushArguments'
        $runner | Should -Match '\$pushArguments\s*=\s*@\('
        $runner | Should -Match '\$pushArguments\s*=\s*@\(''push'',\s*''--set-upstream'',\s*\$State\.remote,\s*\$State\.branch\)'
        $runner | Should -Match 'Assert-AppendOnlyPushArguments -Arguments \$pushArguments'
        $runner | Should -Match 'Invoke-Git[^\r\n]+-Arguments \$pushArguments'
        $runner | Should -Not -Match '\$forbiddenPushOptions\.Count'
        $runner | Should -Match 'append-only'
        $validator | Should -Match 'parent tree'
        $validator | Should -Match 'diff --check'

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $guardAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-AppendOnlyPushArguments'
        }, $true)
        $guardAst | Should -Not -BeNullOrEmpty
        $guardModule = New-Module -ScriptBlock ([scriptblock]::Create($guardAst.Extent.Text))
        try {
            { & $guardModule { Assert-AppendOnlyPushArguments -Arguments @('push', '--set-upstream', 'origin', 'codex/test') -Remote 'origin' -Branch 'codex/test' } } | Should -Not -Throw
            { & $guardModule { Assert-AppendOnlyPushArguments -Arguments @('push', '--force', 'origin', 'codex/test') -Remote 'origin' -Branch 'codex/test' } } | Should -Throw
            { & $guardModule { Assert-AppendOnlyPushArguments -Arguments @('push', '--set-upstream', '--force', 'codex/test') -Remote '--force' -Branch 'codex/test' } } | Should -Throw
        }
        finally {
            Remove-Module $guardModule -Force
        }
    }

    # Scenario: The installed MOD tree is swapped for a junction after localization but before C1/C2/C3 or Candidate validation.
    # Purpose: Recheck the complete physical MOD tree at both boundaries so Git staging, merged localization writes, and Gate reads cannot escape the worktree.
    It 'UnitT145_RechecksThePhysicalInstallTreeBeforeCommitsAndCandidateReads' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        $runner | Should -Match 'function Assert-NoReparseTree'
        $runner | Should -Match '(?s)function Invoke-BuildCommits.*?Assert-NoReparseTree -Path \(\[string\]\$State\.installRoot\) -Root \$worktree -Label ''Installed MOD tree before evidence commits''.*?Write-ByteFile -Path \$destination'
        $runner | Should -Match '(?s)\$destination = Assert-ContainedPath.*?Assert-NoReparsePath -Path \$destination -Root \$worktree -Label ''Merged localization target''.*?Write-ByteFile -Path \$destination'
        $validator | Should -Match 'function Assert-NoReparseTree'
        $validator | Should -Match "Add-ValidationCheck -Name 'physical-install-tree'"
        $validator | Should -Match 'Assert-NoReparsePath -Path \$targetPath -Root \$worktree -Label ''Worktree localization target'''
    }

    # Scenario: The installed MOD root or its immutable workset staging is swapped for a junction before localization generation.
    # Purpose: Reject physical tree indirection before copying or enumerating localization input so outside-worktree bytes cannot become authorized upstream evidence.
    It 'UnitT146_RechecksPhysicalTreesBeforeLocalizationWorksetGeneration' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Match '(?s)function Invoke-LocalizationWorkset.*?Assert-NoReparseTree -Path \(\[string\]\$State\.installRoot\) -Root \(\[string\]\$State\.worktreePath\) -Label ''Installed MOD tree before localization workset staging''.*?Copy-DirectoryBytes -Source \(\[string\]\$State\.installRoot\) -Destination \$stagingModRoot'
        $runner | Should -Match '(?s)Copy-DirectoryBytes -Source \(\[string\]\$State\.installRoot\) -Destination \$stagingModRoot.*?Assert-NoReparseTree -Path \$stagingModRoot -Root \(\[string\]\$State\.runRoot\) -Label ''Localization workset staging tree''.*?& \$generator'
    }

    # Scenario: The installed MOD root is swapped for a junction while localization waits for AI review and the same stage later resumes.
    # Purpose: Reject physical path indirection before reading the raw worktree localization input on resume.
    It 'UnitT147_RechecksTheRawLocalizationPathBeforeResumeReads' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Match '(?s)\$worktreeFile = Assert-ContainedPath.*?\$worktreeFile = Assert-NoReparsePath -Path \$worktreeFile -Root \(\[string\]\$State\.worktreePath\) -Label ''Raw worktree localization input''.*?Get-FileSha256 -Path \$worktreeFile.*?Read-FileBytesWithHeartbeat -Path \$worktreeFile'
    }

    # Scenario: The completed extraction tree is swapped for a junction before install resumes.
    # Purpose: Reject physical tree indirection before directory enumeration so archive files cannot be omitted or sourced outside run-owned staging.
    It 'UnitT148_RechecksThePhysicalExtractionTreeBeforeInstall' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Match '(?s)function Invoke-Install.*?Assert-NoReparseTree -Path \$source -Root \(\[string\]\$State\.runRoot\) -Label ''Verified extracted MOD tree before install''.*?Copy-DirectoryBytes -Source \$source -Destination \$target'
    }

    # Scenario: Validation fails after a candidate is generated.
    # Purpose: Keep validation independent from generation and reject mismatched manifests, byte spans, Git evidence, or artifact hashes.
    It 'UnitT150_KeepsTheCandidateGateIndependentAndFailClosed' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        $runner | Should -Match 'Test-ModUpdateCandidate\.ps1'
        $validator | Should -Match 'candidateGate'
        $validator | Should -Match 'rejected'
        $validator | Should -Match 'manifest'
        $validator | Should -Match "ls-tree', '-r', '-l', '--full-tree'"
        $validator | Should -Match 'Get-GitBlobBytes'
        $validator | Should -Match 'function Assert-ClaimedArchiveIntegrity'
        $validator | Should -Match "Add-ReviewCheck -Name 'claimed-archive'"
        $validator | Should -Match "Add-ValidationCheck -Name 'claimed-archive'"
        $validator | Should -Match 'Assert-NoReparsePath -Path \$archivePath -Root \(\[string\]\$State\.repositoryRoot\) -Label ''Claimed source archive'''
        $validator | Should -Match 'Join-Path \(Join-Path \(\[string\]\$State\.runRoot\) ''source''\) \(\[string\]\$Archive\.filename\)'
        $validator | Should -Match 'Assert-ClaimedArchiveIntegrity -State \$state'
        $validator | Should -Match "Deleted localization workset parent"
        $validator | Should -Not -Match 'Test-ManifestAgainstDirectory'
        $validator | Should -Match 'sha256'
        $validator | Should -Match 'exit 1'

        $runner | Should -Match '\$start\.WorkingDirectory\s*=\s*\[IO\.Path\]::GetFullPath\(\$WorkingDirectory\)'
        $validator | Should -Match '\$start\.WorkingDirectory\s*=\s*\[IO\.Path\]::GetFullPath\(\$WorkingDirectory\)'
        $runnerGhCalls = [regex]::Matches($runner, '(?m)Invoke-Gh\s+-')
        $runnerScopedGhCalls = [regex]::Matches($runner, '(?m)Invoke-Gh\s+-WorkingDirectory\s+\$State\.worktreePath\s+-Arguments')
        $runnerGhCalls.Count | Should -Be $runnerScopedGhCalls.Count
        $validatorGhCalls = [regex]::Matches($validator, '(?m)Invoke-GhCheck\s+-')
        $validatorScopedGhCalls = [regex]::Matches($validator, '(?m)Invoke-GhCheck\s+-WorkingDirectory\s+\$state\.worktreePath\s+-Arguments')
        $validatorGhCalls.Count | Should -Be $validatorScopedGhCalls.Count
    }

    # Scenario: Copilot review is pending, unavailable, or already exists for the immutable PR head.
    # Purpose: Permit exactly one bounded snapshot with no watcher, sleep, or positive polling wait.
    It 'UnitT160_UsesOneZeroWaitExternalReviewSnapshot' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        $runner | Should -Match 'pollingWaitSeconds\s*=\s*0'
        $runner | Should -Match '\$external\.Contains\(''pollingWaitSeconds''\)'
        $runner | Should -Match '\[int64\]\$external\.pollingWaitSeconds\s*-ne\s*0'
        $runner | Should -Not -Match '\$pollingWaitSeconds\s*=\s*0'
        $validator | Should -Match '\$state\.externalReview\.Contains\(''pollingWaitSeconds''\)'
        $runner | Should -Match 'requested-pending'
        $runner | Should -Match 'unavailable'
        $reviewStart = $runner.IndexOf('function Invoke-ReviewSnapshot')
        $reviewEnd = $runner.IndexOf('function Resolve-InitialState', $reviewStart)
        $reviewSnapshot = $runner.Substring($reviewStart, $reviewEnd - $reviewStart)
        $reviewSnapshot | Should -Not -Match 'Start-Sleep|--watch|while\s*\('
    }

    It 'UnitT175_UsesShortSharedLocksAndTokenGuardedReservationHeartbeats' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $coordination = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/SharedCoordinationLock.psm1') -Raw
        $queue = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/Invoke-ModUpdateQueue.ps1') -Raw
        foreach ($contract in @(
            'function Enter-SharedCoordinationLock', 'source-acquisition', 'git-coordination',
            'function Read-ActiveReservationOwner', 'function Write-ActiveReservationOwner',
            'function Update-ActiveReservationHeartbeat', 'function Suspend-ModReservationWorker',
            'reservationToken', 'workerToken', 'workerProcessStartTicks', 'owner-history'
        )) { $runner | Should -Match ([regex]::Escape($contract)) }
        $runner | Should -Match 'lastRecovery = if \(\$plannedOwner\.Contains\(''lastRecovery''\)\)'
        $coordination | Should -Match 'function Enter-SharedCoordinationLease'
        $coordination | Should -Match 'Test-CoordinationLeaseMatchesOwner'
        $coordination | Should -Match '\[int64\]::TryParse\(\[string\]\$Owner\.processStartTicks'
        $coordination | Should -Match '\.stale-\$ResourceKey'
        $coordination | Should -Match '(?s)\$owner\.acquiredAt = Get-CoordinationUtcTimestamp.*?Directory\]::Move\(\$prepared, \$lockPath\)'
        $coordination | Should -Match '\[scriptblock\] \$WaitHeartbeatAction'
        $coordination | Should -Match '\$null = & \$WaitHeartbeatAction'
        $queue | Should -Match 'Enter-SharedCoordinationLease.+source-acquisition'
        $runner | Should -Match '\$gitCommand -in @\(''fetch'', ''push''\)'
        $runner | Should -Match '\$gitCommand -ceq ''worktree'''
        $runner | Should -Match 'HeartbeatAction = \{ Update-ActiveReservationHeartbeat \}'
        $runner | Should -Match '-WaitHeartbeatAction \{ Update-ActiveReservationHeartbeat \}'
        $runner | Should -Match '(?s)finally \{.*?Suspend-ModReservationWorker.*?Exit-RunWriterLock'
        $runner | Should -Match '(?s)if \(-not \[string\]::IsNullOrWhiteSpace\(\$SourceReceiptPath\)\).*?ConvertTo-NexusSourceIdentity.*?\$acquisitionFull.*?\$baseOid = .*?\$plannedOwner = Enter-ModReservation'
        $runner | Should -Match '(?s)else \{.*?ConvertTo-NexusSourceIdentity.*?Source archive must be a regular file.*?\$plannedOwner = Enter-ModReservation.*?for \(\$second = 0; \$second -lt 10'
        $runner | Should -Match '(?s)\$sourceTuple = New-SourceTupleEvidence.*?\$plannedOwner = Read-ActiveReservationOwner'
        $runner | Should -Not -Match '\$gitCommand -in @\([^\)]*''commit'''
        $runner | Should -Not -Match '\$gitCommand -in @\([^\)]*''gh'''
    }

    It 'UnitT176_RequiresUniqueExactLabeledSourceMetadataValues' {
        $candidateSource = Get-Content -LiteralPath $validatorPath -Raw
        $candidateSource | Should -Match '''README\.md''\s*=\s*\$completeSourceFieldNames'
        foreach ($path in @($runnerPath, $validatorPath)) {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
            $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-MetadataSourceFieldMatch'
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
            $invokeMatch = {
                param($relativePath, $textValue, $fieldName, $fieldValue, $nexusPageUrl)
                Test-MetadataSourceFieldMatch -RelativePath $relativePath -Text $textValue -FieldName $fieldName `
                    -FieldValue $fieldValue -NexusPageUrl $nexusPageUrl
            }

            (& $module $invokeMatch 'README.md' '- Archive filename: ExampleMod.zip' 'archiveFileName' 'ExampleMod.zip') |
                Should -BeTrue
            (& $module $invokeMatch 'README.md' '- Archive filename: prefix-ExampleMod.zip.bak' 'archiveFileName' 'ExampleMod.zip') |
                Should -BeFalse
            (& $module $invokeMatch 'README.md' ("- Archive filename: ExampleMod.zip`n- Archive filename: ExampleMod.zip") 'archiveFileName' 'ExampleMod.zip') |
                Should -BeFalse
            (& $module $invokeMatch 'README.md' '- Main file ID: 999' 'nexusMainFileId' '456') |
                Should -BeFalse
            (& $module $invokeMatch '.hash/examplemod.hash' 'filename=ExampleMod.zip' 'archiveFileName' 'ExampleMod.zip') |
                Should -BeTrue
            (& $module $invokeMatch '.hash/examplemod.hash' 'filename=prefix-ExampleMod.zip.bak' 'archiveFileName' 'ExampleMod.zip') |
                Should -BeFalse

            $multiModReadme = @'
### [First MOD](https://www.nexusmods.com/warhammer40kdarktide/mods/1)
- Archive filename: FirstMod.zip

### [Example MOD](https://www.nexusmods.com/warhammer40kdarktide/mods/2?tab=files)
- Archive filename: ExampleMod.zip
'@
            (& $module $invokeMatch 'README.md' $multiModReadme 'archiveFileName' 'ExampleMod.zip' `
                'https://www.nexusmods.com/warhammer40kdarktide/mods/2') | Should -BeTrue
            (& $module $invokeMatch 'README.md' $multiModReadme 'archiveFileName' 'FirstMod.zip' `
                'https://www.nexusmods.com/warhammer40kdarktide/mods/2') | Should -BeFalse

            $nonWwwMultiModReadme = @'
### [First MOD](https://nexusmods.com/warhammer40kdarktide/mods/1/)
- Archive filename: Wrong-Section.zip

### [Example MOD](https://nexusmods.com/warhammer40kdarktide/mods/2/?tab=files)
- Archive filename: ExampleMod.zip
'@
            (& $module $invokeMatch 'README.md' $nonWwwMultiModReadme 'archiveFileName' 'ExampleMod.zip' `
                'https://nexusmods.com/warhammer40kdarktide/mods/2') | Should -BeTrue
            (& $module $invokeMatch 'README.md' $nonWwwMultiModReadme 'archiveFileName' 'Wrong-Section.zip' `
                'https://nexusmods.com/warhammer40kdarktide/mods/2') | Should -BeFalse
        }
    }

    It 'UnitT177_RefreshesLeasesAcrossBlockingProcessesAndChunkedFileOperations' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $candidate = Get-Content -LiteralPath $validatorPath -Raw
        $scanner = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/LuaLocalizationScanner.psm1') -Raw
        $generator = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/New-LocalizationWorkset.ps1') -Raw
        $worksetReceipt = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/Test-LocalizationWorksetReceipt.ps1') -Raw
        $receipt = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/Test-SourceReceipt.ps1') -Raw
        $reference = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts/Test-ReferenceIntegrity.ps1') -Raw
        $runner | Should -Match 'while \(-not \$process\.WaitForExit\(1000\)\)'
        $runner | Should -Match 'function Read-FileBytesWithHeartbeat'
        $runner | Should -Match 'function Copy-FileWithHeartbeat'
        $runner | Should -Match 'function Remove-DirectoryTreeWithHeartbeat'
        $runner | Should -Match 'function Write-BytesWithHeartbeat'
        $runner | Should -Match '\.CopyToAsync\(\$memory\)'
        $runner | Should -Not -Match '\.WaitForExit\(\)'
        $runner | Should -Not -Match '\[IO\.File\]::ReadAllBytes|\[IO\.File\]::Copy|Remove-Item[^\r\n]+-Recurse'
        $candidate | Should -Not -Match '\[IO\.File\]::ReadAllBytes'
        $candidate | Should -Not -Match '-HeartbeatAction \{ Invoke-Heartbeat \}'
        foreach ($content in @($runner, $candidate, $generator, $worksetReceipt)) {
            $content | Should -Match '\.CopyToAsync\(\$memory\)'
            $content | Should -Match 'ReadToEndAsync\(\)'
            $content | Should -Not -Match '\.BaseStream\.CopyTo\('
        }
        $scanner | Should -Match '\[scriptblock\] \$HeartbeatAction'
        $scanner | Should -Match 'function Read-LuaScannerFileBytes'
        $scanner | Should -Match 'function Get-LuaScannerSha256'
        $scanner | Should -Match 'finally \{\s*\$script:luaScannerHeartbeatAction = \$previousHeartbeatAction'
        foreach ($content in @($receipt, $reference)) {
            $content | Should -Match '\[scriptblock\] \$HeartbeatAction'
            $content | Should -Match 'IncrementalHash'
        }
        $runner | Should -Match 'Test-SourceReceipt\.ps1'
        $runner | Should -Match '-HeartbeatAction \{ Update-ActiveReservationHeartbeat \}'
    }

    It 'UnitT178_RejectsAnOldReservationTokenWithoutChangingTheNewOwner' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $requiredFunctions = @('Assert-NoReparsePath', 'Write-AtomicJson', 'Get-ModReservationOwnerPath', 'Write-ModReservationOwner')
        $allFunctions = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
        $functionTexts = foreach ($name in $requiredFunctions) {
            $functionAst = @($allFunctions | Where-Object Name -eq $name)[0]
            $functionAst | Should -Not -BeNullOrEmpty
            $functionAst.Extent.Text
        }
        $module = New-Module -ScriptBlock ([scriptblock]::Create(($functionTexts -join "`n")))
        $repository = Join-Path $TestDrive 'old-reservation-token-repository'
        $lockPath = Join-Path $repository 'AI Auto Update/In Progress/.locks/mod/test.lock'
        New-Item -ItemType Directory -Path $lockPath -Force | Out-Null
        $ownerPath = Join-Path $lockPath 'owner.json'
        $newReservationToken = [guid]::NewGuid().ToString('N')
        $newWorkerToken = [guid]::NewGuid().ToString('N')
        $owner = [ordered]@{
            schemaVersion = 2; runId = '17817817-8178-4178-8178-178178178178'
            reservationToken = $newReservationToken; workerToken = $newWorkerToken
            machineName = [Environment]::MachineName; workerId = $PID; workerProcessStartTicks = 1
            leaseMode = 'active'; heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $owner | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ownerPath -NoNewline
        $ownerBefore = [IO.File]::ReadAllBytes($ownerPath)
        $attempted = $owner | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $attempted.heartbeat = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')
        $invokeWrite = {
            param($actualLockPath, $actualRepository, $value, $reservationToken, $workerToken)
            Write-ModReservationOwner -ModLockPath $actualLockPath -Repository $actualRepository -Value $value `
                -ExpectedReservationToken $reservationToken -ExpectedWorkerToken $workerToken
        }
        { & $module $invokeWrite $lockPath $repository $attempted ([guid]::NewGuid().ToString('N')) $newWorkerToken } |
            Should -Throw '*ownership changed*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($ownerPath)) | Should -Be ([Convert]::ToHexString($ownerBefore))
        { & $module $invokeWrite $lockPath $repository $attempted $newReservationToken $newWorkerToken } |
            Should -Not -Throw
        [DateTimeOffset](Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json).heartbeat |
            Should -Be ([DateTimeOffset]$attempted.heartbeat)
    }

    It 'UnitT179_DoesNotAdoptAnActiveWorkerTokenFromTheSameProcessWithoutItsLease' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-ReservationLeaseMatchesOwner'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $invokeMatch = {
            param($lease, $owner)
            Test-ReservationLeaseMatchesOwner -Lease $lease -Owner $owner
        }
        $owner = [ordered]@{
            runId = '17917917-9179-4179-8179-179179179179'
            reservationToken = [guid]::NewGuid().ToString('N')
            workerToken = [guid]::NewGuid().ToString('N')
            machineName = [Environment]::MachineName
            workerId = $PID
            workerProcessStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
            leaseMode = 'active'
        }
        $lease = $owner | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        (& $module $invokeMatch $null $owner) | Should -BeFalse
        (& $module $invokeMatch $lease $owner) | Should -BeTrue
        $lease.workerToken = [guid]::NewGuid().ToString('N')
        (& $module $invokeMatch $lease $owner) | Should -BeFalse

        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Match '\$sameWorker = Test-ReservationLeaseMatchesOwner -Lease \$script:activeReservationLease -Owner \$owner'
        $runner | Should -Match '(?s)\$createdByThisInvocation = \$publishedPreparedOwner.*?\$sameWorker = \$createdByThisInvocation -or\s+\(Test-ReservationLeaseMatchesOwner'
    }

    # Scenario: A run crashes, repeats a stage, encounters an existing PR, or resumes after publication.
    # Purpose: Require tuple-bound recovery and prevent duplicate commits, PRs, or force-pushed repairs.
    It 'UnitT170_RecordsRecoveryAndIdempotentStageReceipts' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Match 'lastRecovery'
        $runner | Should -Match 'completedStages'
        $runner | Should -Match 'existing PR'
        $runner | Should -Match 'same run'
        $runner | Should -Match 'published'
        $runner | Should -Match 'LocalReviewPath'
        $runner | Should -Match 'review-completion-validation\.json'
        $runner | Should -Match 'function Ensure-RunWriterLock'
        $runner | Should -Match '(?s)function Ensure-RunWriterLock.*?Assert-RunLocalSkillPackage -State \$State.*?Enter-ModReservationWorker -State \$State'
        $runner | Should -Match '(?s)function Get-CompletedStageResult.*?Assert-RunLocalSkillPackage -State \$State.*?Assert-LockOwner -State \$State'
        $runner | Should -Match '(?s)function Ensure-RunWriterLock.*?Enter-ModReservationWorker -State \$State.*?\$script:writerLease = Enter-RunWriterLock -State \$State'
        $runner | Should -Match '(?s)Ensure-RunWriterLock -State \$state\s+Write-AtomicJson -Path \$state\.statePath'
        $runner | Should -Match 'if \(-not \$script:writerLease\)'
        $runner | Should -Match '\$script:writerLease = Enter-RunWriterLock -State \$State'
        $runner | Should -Match '\$pendingWriterRecovery\s*=\s*\$null'
        $runner | Should -Match '(?s)\$script:writerLease = Enter-RunWriterLock -State \$State.*?\$State\.lastRecovery = \$script:writerLease\.recovery.*?Save-State -State \$State'
        $runner | Should -Match 'function Assert-PublishedPrAtF'
        ([regex]::Matches($runner, 'Assert-PublishedPrAtF -State \$State')).Count | Should -Be 3
        $runner | Should -Not -Match '(?s)\$stageName -eq ''review-snapshot''.*?completedStages.*?-notcontains ''review-snapshot'''
        $runner | Should -Match '(?s)foreach \(\$stageName in @\(.*?''review-snapshot''.*?\)\).*?Invoke-StageCommand -StageName \$stageName'
        $runner | Should -Match '(?s)function Invoke-ReviewSnapshot.*?Suspend-Stage.*?-OutputStage ''local-review'''
        $runner | Should -Match '(?s)if \(\$completed\).*?Assert-PublishedPrAtF -State \$State.*?\$State\.status = ''awaiting-user-merge''.*?Save-State -State \$State'
        $baseResolutionIndex = $runner.IndexOf('$baseOid = (Invoke-Git -WorkingDirectory $repository')
        $identityLockIndex = $runner.IndexOf('Enter-ModReservation -Plan $plan', $baseResolutionIndex)
        $baseResolutionIndex | Should -BeGreaterOrEqual 0
        $identityLockIndex | Should -BeGreaterThan $baseResolutionIndex
    }

    Context 'SYP-118 completed-stage run-local Skill pin validation' {
        BeforeEach {
            $script:syp118Fixture = New-TestPinnedCompletedStageRun -SkillRoot $skillRoot `
                -FixtureRoot (Join-Path $TestDrive ("syp118-" + [guid]::NewGuid().ToString('N')))
        }

        AfterEach {
            $fixtureSkillRoot = [IO.Path]::GetFullPath([string]$script:syp118Fixture.SkillRoot)
            Get-Module -Name 'SharedCoordinationLock' | Where-Object {
                $_.Path -and [IO.Path]::GetFullPath([string]$_.Path).StartsWith(
                    $fixtureSkillRoot,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } | Remove-Module -Force
        }

        # Scenario: The installed package still exactly matches the immutable pin archived by the completed run.
        # Purpose: Preserve same-pin idempotency while re-proving the package before receipt reuse.
        It 'InterT171_ReusesACompletedStageWithTheSameRunLocalPin' {
            $stateShaBefore = (Get-FileHash -LiteralPath $script:syp118Fixture.StatePath -Algorithm SHA256).Hash
            $pinShaBefore = (Get-FileHash -LiteralPath $script:syp118Fixture.PinPath -Algorithm SHA256).Hash
            $artifactShaBefore = (Get-FileHash -LiteralPath $script:syp118Fixture.ArtifactPath -Algorithm SHA256).Hash
            $sourceShaBefore = (Get-FileHash -LiteralPath $script:syp118Fixture.SourcePath -Algorithm SHA256).Hash

            $result = & $script:syp118Fixture.RunnerPath verify-source `
                -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                -StatePath $script:syp118Fixture.StatePath -PassThru

            $result.result | Should -Be 'passed'
            $result.idempotent | Should -BeTrue
            $result.stage | Should -Be 'verify-source'
            (Get-FileHash -LiteralPath $script:syp118Fixture.StatePath -Algorithm SHA256).Hash | Should -Be $stateShaBefore
            (Get-FileHash -LiteralPath $script:syp118Fixture.PinPath -Algorithm SHA256).Hash | Should -Be $pinShaBefore
            (Get-FileHash -LiteralPath $script:syp118Fixture.ArtifactPath -Algorithm SHA256).Hash | Should -Be $artifactShaBefore
            (Get-FileHash -LiteralPath $script:syp118Fixture.SourcePath -Algorithm SHA256).Hash | Should -Be $sourceShaBefore
        }

        # Scenario: A non-runner installed package file differs from the content recorded by the run-local pin.
        # Purpose: Reject a completed receipt before state, reservation, source evidence, or pin mutation.
        It 'InterT172_RejectsDifferentPinnedPackageContentBeforeReceiptReuse' {
            [IO.File]::AppendAllText(
                (Join-Path $script:syp118Fixture.SkillRoot 'references/automation.md'),
                "`nSYP-118 package drift`n",
                [Text.UTF8Encoding]::new($false)
            )
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*Installed Skill file differs from its source pin*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }

        # Scenario: A replacement pin keeps the same version and package manifest but names a different commit.
        # Purpose: Make commit identity part of resume authorization instead of trusting SemVer alone.
        It 'InterT173_RejectsTheSameVersionFromADifferentPinnedCommit' {
            $pin = Get-Content -LiteralPath $script:syp118Fixture.PinPath -Raw | ConvertFrom-TestJson -AsHashtable
            $originalVersion = [string]$pin.resolvedVersion
            $pin.resolvedCommit = '2222222222222222222222222222222222222222'
            [IO.File]::WriteAllText(
                $script:syp118Fixture.PinPath,
                ($pin | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $state = Get-Content -LiteralPath $script:syp118Fixture.StatePath -Raw | ConvertFrom-TestJson -AsHashtable
            $state.workflowSourcePinSha256 = (Get-FileHash -LiteralPath $script:syp118Fixture.PinPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $state.workflowSourceVersion | Should -Be $originalVersion
            $state.workflowCommitOid | Should -Not -Be $pin.resolvedCommit
            [IO.File]::WriteAllText(
                $script:syp118Fixture.StatePath,
                ($state | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*resolvedCommit*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }

        # Scenario: The executing mod-update.ps1 bytes drift after the run archives its immutable package pin.
        # Purpose: Prove the runner cannot authorize reuse of its own completed-stage receipt after self drift.
        It 'InterT174_RejectsRunnerFileDriftBeforeStateOrLockMutation' {
            [IO.File]::AppendAllText(
                $script:syp118Fixture.RunnerPath,
                "`n# SYP-118 runner drift`n",
                [Text.UTF8Encoding]::new($false)
            )
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*mod-update.ps1*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }

        # Scenario: A pre-0.3 Schema 14 completed run has no run-local pin but retains its immutable authoring references.
        # Purpose: Exercise the real resume path and preserve compatibility without creating or migrating pin evidence.
        It 'InterT175_ResumesALegacySchema14RunWithoutMigratingItsPin' {
            $integrity = & (Join-Path $script:syp118Fixture.SkillRoot 'scripts/Test-ReferenceIntegrity.ps1') -PassThru
            $state = Get-Content -LiteralPath $script:syp118Fixture.StatePath -Raw | ConvertFrom-TestJson -AsHashtable
            foreach ($field in @(
                'workflowSourcePinPath', 'workflowSourcePinSha256', 'workflowSourceRepository',
                'workflowSourceVersion', 'workflowSourceContentSha256'
            )) { $state.Remove($field) }
            $state.schemaVersion = 14
            $state.workflowSchemaVersion = 14
            $state.workflowCommitOid = [string]$integrity.authoringSourceCommit
            $state.workflowPath = [string]$integrity.workflow.originalPath
            $state.workflowBlobOid = [string]$integrity.workflow.gitBlobOid
            $state.workflowSha256 = [string]$integrity.workflow.sha256
            $state.reviewBaselinePath = [string]$integrity.reviewBaseline.originalPath
            $state.reviewBaselineBlobOid = [string]$integrity.reviewBaseline.gitBlobOid
            $state.reviewBaselineSha256 = [string]$integrity.reviewBaseline.sha256
            [IO.File]::WriteAllText(
                $script:syp118Fixture.StatePath,
                ($state | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            [IO.File]::Delete($script:syp118Fixture.PinPath)
            $stateShaBefore = (Get-FileHash -LiteralPath $script:syp118Fixture.StatePath -Algorithm SHA256).Hash

            $result = & $script:syp118Fixture.RunnerPath verify-source `
                -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                -StatePath $script:syp118Fixture.StatePath -PassThru

            $result.result | Should -Be 'passed'
            $result.idempotent | Should -BeTrue
            (Get-FileHash -LiteralPath $script:syp118Fixture.StatePath -Algorithm SHA256).Hash | Should -Be $stateShaBefore
            Test-Path -LiteralPath $script:syp118Fixture.PinPath | Should -BeFalse
        }

        # Scenario: A Schema 15 completed run loses both recorded run-local pin fields before resume.
        # Purpose: Fail before reservation or state mutation instead of silently entering the Schema 14 compatibility path.
        It 'InterT176_RejectsANonLegacyRunWhosePinRecordIsMissing' {
            $state = Get-Content -LiteralPath $script:syp118Fixture.StatePath -Raw | ConvertFrom-TestJson -AsHashtable
            $state.Remove('workflowSourcePinPath')
            $state.Remove('workflowSourcePinSha256')
            [IO.File]::WriteAllText(
                $script:syp118Fixture.StatePath,
                ($state | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*Run-local Skill source pin is missing*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }

        # Scenario: A Schema 15 completed run retains the pin path but loses the recorded pin SHA-256.
        # Purpose: Reject a partial pin tuple before any writer or reservation mutation.
        It 'InterT177_RejectsAnIncompleteRunLocalPinRecord' {
            $state = Get-Content -LiteralPath $script:syp118Fixture.StatePath -Raw | ConvertFrom-TestJson -AsHashtable
            $state.Remove('workflowSourcePinSha256')
            [IO.File]::WriteAllText(
                $script:syp118Fixture.StatePath,
                ($state | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*pin record is incomplete*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }

        # Scenario: A Schema 15 state is edited to reference a pin outside its fixed run-local evidence path.
        # Purpose: Reject pin relocation before reading alternate bytes or acquiring the reservation worker.
        It 'InterT178_RejectsRunLocalPinPathRelocation' {
            $state = Get-Content -LiteralPath $script:syp118Fixture.StatePath -Raw | ConvertFrom-TestJson -AsHashtable
            $alternatePin = Join-Path $script:syp118Fixture.RunRoot 'alternate-pin.json'
            [IO.File]::Copy($script:syp118Fixture.PinPath, $alternatePin)
            $state.workflowSourcePinPath = [IO.Path]::GetFullPath($alternatePin)
            [IO.File]::WriteAllText(
                $script:syp118Fixture.StatePath,
                ($state | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath,
                $alternatePin
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*pin path changed*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }

        # Scenario: The fixed run-local pin remains valid JSON but its bytes change after the state records its SHA-256.
        # Purpose: Reject any pin rewrite even when its semantic fields still describe the same package.
        It 'InterT179_RejectsChangedRunLocalPinBytes' {
            [IO.File]::AppendAllText($script:syp118Fixture.PinPath, "`n", [Text.UTF8Encoding]::new($false))
            $protectedPaths = @(
                $script:syp118Fixture.StatePath,
                $script:syp118Fixture.PinPath,
                $script:syp118Fixture.OwnerPath,
                $script:syp118Fixture.ArtifactPath,
                $script:syp118Fixture.SourcePath
            )
            $before = @{}
            foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

            { & $script:syp118Fixture.RunnerPath verify-source `
                    -RepositoryRoot $script:syp118Fixture.RepositoryRoot `
                    -StatePath $script:syp118Fixture.StatePath -PassThru } |
                Should -Throw '*Skill package drift*pin bytes*'

            foreach ($path in $protectedPaths) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before[$path] -Because $path
            }
        }
    }

    # Scenario: A maintainer installs the Skill, recovers a failed run, rolls back, or adds a MOD exception.
    # Purpose: Keep operational documentation and known limitations available without loading it for unrelated Schema 14 steps.
    It 'UnitT180_DocumentsOperationRecoveryRollbackAndModExceptions' {
        $automation = Get-Content -LiteralPath (Join-Path $skillRoot 'references/automation.md') -Raw

        foreach ($topic in @('Install', 'Usage', 'Recovery', 'Rollback', 'Known limitations', 'MOD exceptions')) {
            $automation | Should -Match ([regex]::Escape($topic))
        }
        $automation | Should -Match 'awaiting-user-merge'
        $automation | Should -Match 'state\.json'
    }

    # Scenario: README or the first-time formal hash metadata is absent when build-commits starts.
    # Purpose: Pause for explicit Agent preparation before C1 without recording a failed run or partial evidence commits.
    It 'UnitT181_SuspendsForFirstTimeMetadataPreparationBeforeCreatingC1' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functions = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
        $metadataFunction = @($functions | Where-Object Name -eq 'Assert-BuildMetadataPaths')[0]
        $buildFunction = @($functions | Where-Object Name -eq 'Invoke-BuildCommits')[0]
        $metadataFunction | Should -Not -BeNullOrEmpty
        $buildFunction | Should -Not -BeNullOrEmpty
        $moduleSource = @'
function Assert-ContainedPath { param($Candidate, $Root, $Label) [IO.Path]::GetFullPath($Candidate) }
function Assert-NoReparsePath { param($Path, $Root, $Label, [switch]$AllowMissing) [IO.Path]::GetFullPath($Path) }
'@ + "`n" + $metadataFunction.Extent.Text
        $module = New-Module -ScriptBlock ([scriptblock]::Create($moduleSource))
        $worktree = Join-Path $TestDrive 'metadata-preflight-worktree'
        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $worktree 'README.md'), 'ready', [Text.UTF8Encoding]::new($false))
        $state = [ordered]@{
            worktreePath = $worktree
            modSlug = 'examplemod'
            metadataPaths = @('README.md', '.hash/examplemod.hash')
        }

        { & $module { param($value) Assert-BuildMetadataPaths -State $value } $state } |
            Should -Throw '*Metadata path is missing: .hash/examplemod.hash*'
        $preparation = @(& $module { param($value) Assert-BuildMetadataPaths -State $value -AllowMissing } $state)
        $preparation.Count | Should -Be 2
        @($preparation | Where-Object { -not $_.exists }).relativePath | Should -Be @('.hash/examplemod.hash')
        $buildText = $buildFunction.Extent.Text
        $readinessIndex = $buildText.IndexOf('Assert-BuildMetadataPaths -State $State -AllowMissing', [StringComparison]::Ordinal)
        $suspendIndex = $buildText.IndexOf("-OutputStage 'metadata-preparation'", [StringComparison]::Ordinal)
        $preflightIndex = $buildText.IndexOf('New-BuildMetadataPreview -State $State', [StringComparison]::Ordinal)
        $c1CommitIndex = $buildText.IndexOf('sync upstream non-localization [C1]', [StringComparison]::Ordinal)
        $readinessIndex | Should -BeGreaterOrEqual 0
        $suspendIndex | Should -BeGreaterThan $readinessIndex
        $preflightIndex | Should -BeGreaterOrEqual 0
        $preflightIndex | Should -BeGreaterThan $suspendIndex
        $c1CommitIndex | Should -BeGreaterThan $preflightIndex
    }

    # Scenario: a crash recovery or external Git operation leaves an unrelated path staged before a checkpoint commit.
    # Purpose: Fail before C1/C2/C3/F can absorb out-of-scope index entries, and run Git's whitespace/error check on every staged checkpoint.
    It 'UnitT181A_EnforcesTheStagedIndexBoundaryBeforeEveryCheckpointCommit' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functions = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
        $guardFunction = @($functions | Where-Object Name -eq 'Assert-StagedCheckpointBoundary')[0]
        $buildFunction = @($functions | Where-Object Name -eq 'Invoke-BuildCommits')[0]
        $guardFunction | Should -Not -BeNullOrEmpty
        $buildFunction | Should -Not -BeNullOrEmpty

        $moduleSource = @'
function Invoke-Git {
    param([string] $WorkingDirectory, [string[]] $Arguments, [switch] $AllowFailure)
    $output = & git -C $WorkingDirectory @Arguments 2>&1 | Out-String
    $result = [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output.TrimEnd(); warning = '' }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw $result.output }
    $result
}
'@ + "`n" + $guardFunction.Extent.Text
        $module = New-Module -ScriptBlock ([scriptblock]::Create($moduleSource))
        $repository = Join-Path $TestDrive 'checkpoint-index-boundary'
        New-Item -ItemType Directory -Path (Join-Path $repository 'mods/ExampleMod') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $repository 'mods/ExampleMod/upstream.txt'), "old`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $repository 'outside.txt'), "old`n", [Text.UTF8Encoding]::new($false))
        & git -C $repository init --quiet --initial-branch=main
        & git -C $repository config user.name 'Fixture User'
        & git -C $repository config user.email 'fixture@example.invalid'
        & git -C $repository add --all
        & git -C $repository commit --quiet -m baseline
        try {
            [IO.File]::WriteAllText((Join-Path $repository 'mods/ExampleMod/upstream.txt'), "new`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $repository 'outside.txt'), "changed`n", [Text.UTF8Encoding]::new($false))
            & git -C $repository add --all

            { & $module {
                    param($worktree)
                    Assert-StagedCheckpointBoundary -WorkingDirectory $worktree -Checkpoint 'C1' -AllowedRoot 'mods/ExampleMod'
                } $repository } | Should -Throw '*C1 staged path is outside its allowlist: outside.txt*'

            & git -C $repository reset --quiet HEAD -- outside.txt
            { & $module {
                    param($worktree)
                    Assert-StagedCheckpointBoundary -WorkingDirectory $worktree -Checkpoint 'C1' -AllowedRoot 'mods/ExampleMod'
                } $repository } | Should -Not -Throw
        }
        finally {
            Remove-Module $module -Force
        }

        $buildText = $buildFunction.Extent.Text
        foreach ($checkpoint in @('C1', 'C2', 'C3', 'F')) {
            $buildText | Should -Match ("Assert-StagedCheckpointBoundary[^`r`n]+-Checkpoint '$checkpoint'")
        }
        ([regex]::Matches($buildText, 'Assert-StagedCheckpointBoundary')).Count | Should -Be 4
    }

    # Scenario: Localization is not applicable, so C2 and C3 have no parent or checkpoint tree OID.
    # Purpose: Keep the producer's structured KEEP contract byte-identical to the independent Gate's null-valued reconstruction.
    It 'UnitT201_PreservesNullTreesInNotApplicableCheckpointReasons' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $reasonFunction = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CheckpointReason'
        }, $true))[0]
        $reasonFunction | Should -Not -BeNullOrEmpty
        $moduleSource = @'
function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-FileSha256 { param([string] $Path) 'a' * 64 }
function Get-SourceTupleContractSha256 {
    param([Collections.IDictionary] $Contract)
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($Contract | ConvertTo-Json -Depth 20 -Compress)))
}
'@ + "`n" + $reasonFunction.Extent.Text
        $module = New-Module -ScriptBlock ([scriptblock]::Create($moduleSource))
        $manifestPath = Join-Path $TestDrive 'localization-manifest.json'
        [IO.File]::WriteAllText($manifestPath, '{"mode":"none"}', [Text.UTF8Encoding]::new($false))
        $targetSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes('[]'))).ToLowerInvariant()
        $state = [ordered]@{
            schemaVersion = 14
            localizationMode = 'none'
            evidenceTargetPaths = @()
            evidenceTargetPathsSha256 = $targetSha
            localizationManifestPath = $manifestPath
        }

        $reason = & $module { param($value) New-CheckpointReason -State $value -Checkpoint C2 -ParentTreeOid $null -TreeOid $null } $state
        ($null -eq $reason.parentTreeOid) | Should -BeTrue
        ($null -eq $reason.treeOid) | Should -BeTrue
        $expectedContract = [ordered]@{
            checkpoint = 'C2'; code = 'localization-not-applicable'; disposition = 'KEEP'; localizationMode = 'none'
            parentTreeOid = $null; treeOid = $null; targetPathsSha256 = $targetSha; targetPathCount = 0
            localizationManifestSha256 = 'a' * 64
        }
        $expectedSha = & $module { param($contract) Get-SourceTupleContractSha256 -Contract $contract } $expectedContract
        $reason.contractSha256 | Should -Be $expectedSha
    }

    # Scenario: build-commits failed after C1 and state retained the exact C1 OID and tree.
    # Purpose: Resume the same generation from C1 only when HEAD still matches the recorded checkpoint tuple.
    It 'UnitT182_ResumesTheRecordedC1PartialCheckpoint' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BuildCommitsResumeCheckpoint'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $c0 = '0' * 40
        $c1 = '1' * 40
        $c0Tree = 'a' * 40
        $c1Tree = 'b' * 40
        $state = [ordered]@{ evidenceChain = [ordered]@{
            c0Oid = $c0; c0TreeOid = $c0Tree; c1Oid = $c1; c1TreeOid = $c1Tree
            c2Oid = $null; c2TreeOid = $null; c3Oid = $null; c3TreeOid = $null; fOid = $null; fTreeOid = $null
        } }

        (& $module { param($value, $head, $tree) Get-BuildCommitsResumeCheckpoint -State $value -HeadOid $head -HeadTreeOid $tree } `
            $state $c1 $c1Tree) | Should -Be 'c1'
        { & $module { param($value, $head, $tree) Get-BuildCommitsResumeCheckpoint -State $value -HeadOid $head -HeadTreeOid $tree } `
                $state $c1 ('c' * 40) } | Should -Throw '*partial checkpoint tree*'
    }

    # Scenario: build-commits failed after C3 and state retained the exact C1/C2/C3 chain.
    # Purpose: Continue with metadata and evidence generation without creating duplicate C1/C2/C3 commits.
    It 'UnitT183_ResumesTheRecordedC3PartialCheckpoint' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-BuildCommitsResumeCheckpoint'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $state = [ordered]@{ evidenceChain = [ordered]@{
            c0Oid = '0' * 40; c0TreeOid = 'a' * 40; c1Oid = '1' * 40; c1TreeOid = 'b' * 40
            c2Oid = '2' * 40; c2TreeOid = 'c' * 40; c3Oid = '3' * 40; c3TreeOid = 'd' * 40
            fOid = $null; fTreeOid = $null
        } }

        (& $module { param($value) Get-BuildCommitsResumeCheckpoint -State $value -HeadOid ('3' * 40) -HeadTreeOid ('d' * 40) } $state) |
            Should -Be 'c3'
    }

    # Scenario: a failed partial attempt is followed by a deterministic same-run success.
    # Purpose: Preserve the failed timing record instead of overwriting it when the resumed attempt passes.
    It 'UnitT184_PreservesFailedAttemptHistoryAfterSuccessfulResume' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-StageAttemptHistory'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $failed = [ordered]@{ attempt = 1; result = 'failed'; partialCheckpoint = 'c1' }
        $timing = [ordered]@{ attempt = 1; result = 'failed'; attempts = @($failed) }
        $history = @(& $module { param($value) Get-StageAttemptHistory -Timing $value } $timing)

        $history.Count | Should -Be 1
        $history[0].result | Should -Be 'failed'
        $history[0].partialCheckpoint | Should -Be 'c1'
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Match 'recoveryDisposition'
        $runner | Should -Match 'same-run-checkpoint-resume'
    }

    # Scenario: a state-mutating resume presents a pin whose bytes no longer equal the run-local pin receipt.
    # Purpose: Reject package drift before any completed-stage receipt can be reused.
    It 'UnitT185_RejectsRunLocalPinContentDrift' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-RunLocalSkillPinRecord'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $pin = [ordered]@{
            repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
            requestedRef = 'test-fixture'
            resolvedCommit = '1' * 40; resolvedVersion = '0.3.1'; contentSha256 = 'a' * 64; pinSha256 = 'b' * 64
        }
        $state = [ordered]@{
            workflowSourceRepository = $pin.repository; workflowRef = $pin.requestedRef; workflowCommitOid = $pin.resolvedCommit
            workflowSourceVersion = $pin.resolvedVersion; workflowSourceContentSha256 = $pin.contentSha256
            workflowSourcePinSha256 = $pin.pinSha256
        }

        { & $module { param($value, $record) Assert-RunLocalSkillPinRecord -State $value -PinRecord $record -ActualPinSha256 ('c' * 64) } `
                $state $pin } | Should -Throw '*Skill package drift*pin bytes*'
    }

    # Scenario: installed package metadata reports the same version but a different immutable commit from the run.
    # Purpose: Treat commit identity as authoritative and never migrate the old run pin to the current package.
    It 'UnitT186_RejectsTheSameVersionFromADifferentCommit' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-RunLocalSkillPinRecord'
        }, $true)
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $pin = [ordered]@{
            repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
            requestedRef = 'test-fixture'
            resolvedCommit = '2' * 40; resolvedVersion = '0.3.1'; contentSha256 = 'a' * 64; pinSha256 = 'b' * 64
        }
        $state = [ordered]@{
            workflowSourceRepository = $pin.repository; workflowRef = $pin.requestedRef; workflowCommitOid = '1' * 40
            workflowSourceVersion = $pin.resolvedVersion; workflowSourceContentSha256 = $pin.contentSha256
            workflowSourcePinSha256 = $pin.pinSha256
        }

        { & $module { param($value, $record) Assert-RunLocalSkillPinRecord -State $value -PinRecord $record -ActualPinSha256 $record.pinSha256 } `
                $state $pin } | Should -Throw '*Skill package drift*commit*'
    }

    # Scenario: a caller resumes a completed stage under the identical immutable package pin.
    # Purpose: Verify the pin before writer acquisition and again inside the completed-stage fast path while retaining idempotency.
    It 'UnitT187_PreflightsTheIdenticalPinBeforeWriterAndCompletedReceiptReuse' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $completedFunctionStart = $runner.IndexOf('function Get-CompletedStageResult', [StringComparison]::Ordinal)
        $completedFunctionEnd = $runner.IndexOf('function Assert-LockOwner', $completedFunctionStart, [StringComparison]::Ordinal)
        $completedFunction = $runner.Substring($completedFunctionStart, $completedFunctionEnd - $completedFunctionStart)
        $completedFunction | Should -Match 'Assert-RunLocalSkillPackage -State \$State'
        $resumePreflightIndex = $runner.IndexOf('Assert-RunLocalSkillPackage -State $state', $runner.IndexOf("elseif (`$Command -eq 'run')", [StringComparison]::Ordinal), [StringComparison]::Ordinal)
        $writerIndex = $runner.IndexOf('Ensure-RunWriterLock -State $state', $runner.IndexOf("elseif (`$Command -eq 'run')", [StringComparison]::Ordinal), [StringComparison]::Ordinal)
        $resumePreflightIndex | Should -BeGreaterOrEqual 0
        $writerIndex | Should -BeGreaterThan $resumePreflightIndex
    }

    # Scenario: package drift is detected after a writer was acquired but before a completed receipt is reused.
    # Purpose: Report the drift while preserving the old run state, source, lock identity, and immutable pin evidence.
    It 'UnitT188_DoesNotWritePackageDriftIntoThePinnedRunState' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Match '(?s)catch \{.*?\$isPackageDrift.*?if \(-not \$isPackageDrift -and \$writerLease'
    }

    # Scenario: a pre-0.3 Schema 14 run has no run-local pin and presents its recorded authoring-reference tuple.
    # Purpose: Preserve legacy compatibility only when the installed Workflow and Review Baseline still match that tuple.
    It 'UnitT189_ValidatesTheLegacySchema14AuthoringTupleWithoutMigratingIt' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-LegacySchema14SkillPackageRecord'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $integrity = [ordered]@{
            result = 'passed'
            authoringSourceCommit = '1' * 40
            workflow = [ordered]@{ originalPath = 'AI Prompt/workflow.md'; gitBlobOid = '2' * 40; sha256 = 'a' * 64 }
            reviewBaseline = [ordered]@{ originalPath = 'AI Prompt/review.md'; gitBlobOid = '3' * 40; sha256 = 'b' * 64 }
        }
        $state = [ordered]@{
            schemaVersion = 14
            workflowCommitOid = $integrity.authoringSourceCommit
            workflowPath = $integrity.workflow.originalPath
            workflowBlobOid = $integrity.workflow.gitBlobOid
            workflowSha256 = $integrity.workflow.sha256
            reviewBaselinePath = $integrity.reviewBaseline.originalPath
            reviewBaselineBlobOid = $integrity.reviewBaseline.gitBlobOid
            reviewBaselineSha256 = $integrity.reviewBaseline.sha256
        }

        (& $module { param($value, $record) Assert-LegacySchema14SkillPackageRecord -State $value -Integrity $record } `
            $state $integrity).result | Should -Be 'legacy-schema-14'
        $state.workflowCommitOid = '4' * 40
        { & $module { param($value, $record) Assert-LegacySchema14SkillPackageRecord -State $value -Integrity $record } `
                $state $integrity } | Should -Throw '*legacy Schema 14 authoring reference tuple*'
    }

    # Scenario: Schema 15 pauses after it has started localization because AI decisions are still required.
    # Purpose: Preserve that waiting attempt and clear the active stage context so same-run resume has complete timing evidence.
    It 'UnitT190_RecordsWaitingInputAsAResumableStageAttempt' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Match 'function Suspend-Stage'
        $localizationStart = $runner.IndexOf('function Invoke-LocalizationWorkset', [StringComparison]::Ordinal)
        $localizationEnd = $runner.IndexOf('function Invoke-Localization', $localizationStart + 1, [StringComparison]::Ordinal)
        $localizationFunction = $runner.Substring($localizationStart, $localizationEnd - $localizationStart)
        ([regex]::Matches($localizationFunction, 'Suspend-Stage -State \$State -Context \$stage')).Count | Should -Be 2
        $localizationFunction | Should -Match "-Result 'waiting-input'"
    }

    # Scenario: A PR keeps the immutable F head but its evidence summary body is stale or externally edited.
    # Purpose: Reject Review completion unless the remote PR body still carries the current Gate/evidence tuple.
    It 'UnitT191_RevalidatesTheRemotePrEvidenceSummary' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $assertStart = $runner.IndexOf('function Assert-PublishedPrAtF', [StringComparison]::Ordinal)
        $assertEnd = $runner.IndexOf('function Invoke-Publish', $assertStart, [StringComparison]::Ordinal)
        $assertFunction = $runner.Substring($assertStart, $assertEnd - $assertStart)
        $assertFunction | Should -Match "headRefOid,body"
        $assertFunction | Should -Match 'Get-PrBody -State \$State'
        $assertFunction | Should -Match 'Published PR evidence summary body changed'
        $runner | Should -Match '(?s)pr'', ''edit''.*?--body'', \$updatedBody.*?Assert-PublishedPrAtF -State \$State'
        $validator | Should -Match 'function Assert-PrBodyEvidenceSummary'
        $validator | Should -Match "Add-ReviewCheck -Name 'pr-evidence-summary'"
    }

    # Scenario: The evidence receipt claims that the coordinator checked every changed-path boundary.
    # Purpose: Require reconstructible range/allowlist evidence instead of accepting a self-asserted passed string.
    It 'UnitT192_ReconstructsCoordinatorChangedPathAllowlists' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        $runner | Should -Match 'function Assert-EvidenceChangedPathAllowlists'
        $runner | Should -Match '\$changedPathVerification\s*=\s*Assert-EvidenceChangedPathAllowlists -State \$State'
        $runner | Should -Match 'changedPathAllowlists\s*=\s*\$changedPathVerification'
        $validator | Should -Match '\$verification\.changedPathAllowlists\.result\s*-cne\s*''passed'''
        $validator | Should -Match 'changedPathAllowlists\.contractSha256'
        $validator | Should -Match 'evidence-generation-receipt coordinator changed-path allowlists changed'
    }

    # Scenario: Review completion is resumed or independently rechecked after Gate artifacts or review content drift.
    # Purpose: Bind the completion decision to the immutable evidence receipt, Candidate Gate SHA, and actionable finding schema.
    It 'UnitT193_RevalidatesImmutableEvidenceAndLocalReviewAtCompletion' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $reviewStart = $runner.IndexOf('function Invoke-ReviewSnapshot', [StringComparison]::Ordinal)
        $reviewEnd = $runner.IndexOf('function Resolve-InitialState', $reviewStart, [StringComparison]::Ordinal)
        $reviewFunction = $runner.Substring($reviewStart, $reviewEnd - $reviewStart)
        $completionStart = $validator.IndexOf('if ($ReviewCompletion)', [StringComparison]::Ordinal)
        $completionEnd = $validator.IndexOf('$checks = [ordered]@{}', $completionStart, [StringComparison]::Ordinal)
        $completionBlock = $validator.Substring($completionStart, $completionEnd - $completionStart)

        $reviewFunction | Should -Match '(?s)if \(\$completed\).*?Test-ModUpdateCandidate\.ps1.*?-ReviewCompletion'
        $completionBlock | Should -Match "Add-ReviewCheck -Name 'evidence-generation-receipt'"
        $completionBlock | Should -Match 'Assert-EvidenceGenerationReceiptIntegrity -State \$state'
        $completionBlock | Should -Match '\$review\.candidateGateSha256\s*-ne\s*\$state\.candidateGate\.validationReportSha256'
        foreach ($field in @('priority', 'location', 'violatedBaseline', 'evidence', 'consequence', 'disposition')) {
            $completionBlock | Should -Match ([regex]::Escape("'$field'"))
        }
    }

    # Scenario: GitHub accepts no Copilot review request for the current F.
    # Purpose: Record unavailable with failure evidence instead of falsely claiming a request is pending.
    It 'UnitT194_DoesNotCallAFailedExternalReviewRequestPending' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $reviewStart = $runner.IndexOf('function Invoke-ReviewSnapshot', [StringComparison]::Ordinal)
        $reviewEnd = $runner.IndexOf('function Resolve-InitialState', $reviewStart, [StringComparison]::Ordinal)
        $reviewFunction = $runner.Substring($reviewStart, $reviewEnd - $reviewStart)

        $reviewFunction | Should -Match '(?s)\$request\s*=\s*Invoke-Gh.*?if \(\$request\.exitCode -ne 0\).*?status\s*=\s*''unavailable'''
        $reviewFunction | Should -Match 'External Review request failed'
    }

    # Scenario: A source archive adds or changes executable, script, or nested-archive payload bytes.
    # Purpose: Stop before publishing extracted bytes unless an exact archive/path/file-SHA approval exists.
    It 'UnitT195_GatesChangedRiskyArchivePayloads' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $extractStart = $runner.IndexOf('function Invoke-Extract', [StringComparison]::Ordinal)
        $extractEnd = $runner.IndexOf('function Copy-DirectoryBytes', $extractStart, [StringComparison]::Ordinal)
        $extractFunction = $runner.Substring($extractStart, $extractEnd - $extractStart)

        $runner | Should -Match 'function Get-ArchivePayloadRisk'
        $runner | Should -Match 'function Assert-ArchivePayloadSecurity'
        $runner | Should -Match '(?i)\.dll'
        $runner | Should -Match '(?i)nested-archive'
        $runner | Should -Match 'archiveSha256'
        $runner | Should -Match 'fileSha256'
        $extractFunction | Should -Match 'Assert-ArchivePayloadSecurity -State \$State -ExtractedRoot \$temporaryRoot'
        $extractFunction.IndexOf('Assert-ArchivePayloadSecurity', [StringComparison]::Ordinal) |
            Should -BeLessThan $extractFunction.IndexOf('[IO.Directory]::Move', [StringComparison]::Ordinal)
    }

    # Scenario: Risk classification receives known risky content plus Windows ZIP external attributes whose upper word overlaps Unix execute bits.
    # Purpose: Preserve executable/script/archive blocking without treating DOS metadata as Unix executable permissions in either security implementation.
    It 'UnitT196_ClassifiesRiskyPayloadContentAndExtensions' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $riskFunction = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ArchivePayloadRisk'
        }, $true)
        $riskFunction | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($riskFunction.Extent.Text))

        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/payload.dll' -Bytes ([byte[]](1, 2)) }) | Should -Be 'native-executable'
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/nested.zip' -Bytes ([byte[]](1, 2)) }) | Should -Be 'nested-archive'
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/install.ps1' -Bytes ([byte[]](1, 2)) }) | Should -Be 'install-or-system-script'
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/unknown.bin' -Bytes ([byte[]](0x7F, 0x45, 0x4C, 0x46)) }) | Should -Be 'native-executable'
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/localization.lua' -Bytes ([byte[]](1, 2)) }) | Should -BeNullOrEmpty
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/ExampleMod.mod' -Bytes ([byte[]](1, 2)) -ExternalAttributes 0x00080020 }) | Should -BeNullOrEmpty
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/tool' -Bytes ([byte[]](1, 2)) -ExternalAttributes 0x81ED0000 }) | Should -Be 'native-executable'
        (& $module { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/tool' -Bytes ([byte[]](1, 2)) -ExternalAttributes 0x01ED0000 }) | Should -Be 'native-executable'

        $validatorTokens = $null
        $validatorParseErrors = $null
        $validatorAst = [Management.Automation.Language.Parser]::ParseFile($validatorPath, [ref]$validatorTokens, [ref]$validatorParseErrors)
        @($validatorParseErrors).Count | Should -Be 0
        $validatorRiskFunction = $validatorAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ArchivePayloadRisk'
        }, $true)
        $validatorRiskFunction | Should -Not -BeNullOrEmpty
        $validatorModule = New-Module -ScriptBlock ([scriptblock]::Create($validatorRiskFunction.Extent.Text))
        (& $validatorModule { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/ExampleMod.mod' -Bytes ([byte[]](1, 2)) -ExternalAttributes 0x00080020 }) | Should -BeNullOrEmpty
        (& $validatorModule { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/tool' -Bytes ([byte[]](1, 2)) -ExternalAttributes 0x81ED0000 }) | Should -Be 'native-executable'
        (& $validatorModule { Get-ArchivePayloadRisk -RelativePath 'ExampleMod/tool' -Bytes ([byte[]](1, 2)) -ExternalAttributes 0x01ED0000 }) | Should -Be 'native-executable'
    }

    It 'UnitT197_ImportsSecurityApprovalAsAnAuditedRunArtifact' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Match '\[string\]\s*\$SecurityOverridePath'
        $runner | Should -Match 'function Import-SecurityOverrides'
        $runner | Should -Match 'security-overrides\.json'
        $runner | Should -Match 'runId'
        $runner | Should -Match 'archiveSha256'
        $runner | Should -Match '(?s)function Invoke-Extract.*?Import-SecurityOverrides -State \$State -Path \$SecurityOverridePath.*?Assert-ArchivePayloadSecurity'
    }

    It 'UnitT198_IndependentlyReconstructsRiskyPayloadApprovalAtTheCandidateGate' {
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $validator | Should -Match 'function Get-ArchivePayloadRisk'
        $validator | Should -Match 'function Assert-ArchivePayloadSecurityIntegrity'
        $validator | Should -Match "Add-ValidationCheck -Name 'security-payload'"
        $validator | Should -Match 'securityOverrideReceipt'
        $validator | Should -Match 'approved-exact-tuple'
        $validator | Should -Match 'unchanged-from-c0'
    }

    It 'UnitT199_ReconstructsEveryExternalReviewTerminalObservation' {
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $completionStart = $validator.IndexOf('if ($ReviewCompletion)', [StringComparison]::Ordinal)
        $completionEnd = $validator.IndexOf('$checks = [ordered]@{}', $completionStart, [StringComparison]::Ordinal)
        $completionBlock = $validator.Substring($completionStart, $completionEnd - $completionStart)
        $completionBlock | Should -Match 'switch \(\[string\]\$state\.externalReview\.status\)'
        foreach ($field in @('requestEvidence', 'reviewId', 'reviewerLogin', 'submittedAt', 'reviewCommitOid', 'snapshotAt', 'verifiedAt', 'reason')) {
            $completionBlock | Should -Match ([regex]::Escape($field))
        }
        $completionBlock | Should -Match 'External Review head does not equal F'
    }

    It 'UnitT202_RendersAndValidatesExactSecurityApprovalEvidenceInThePrBody' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $runner | Should -Match '\$securityOverrideSummary'
        $runner | Should -Match 'archiveSha256=.*relativePath=.*fileSha256='
        $runner | Should -Match 'Security override receipt SHA-256'
        $validator | Should -Match 'Security override receipt SHA-256'
    }

    # Scenario: A build resumes after extraction while its exact risky-payload approval evidence may have drifted.
    # Purpose: Re-run the independent payload-security verifier before any checkpoint commit can be created or resumed.
    It 'UnitT203_RevalidatesPayloadSecurityBeforeCheckpointCommits' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $buildStart = $runner.IndexOf('function Invoke-BuildCommits', [StringComparison]::Ordinal)
        $buildEnd = $runner.IndexOf('function Invoke-Validate', $buildStart, [StringComparison]::Ordinal)
        $buildFunction = $runner.Substring($buildStart, $buildEnd - $buildStart)

        $validator | Should -Match '\[switch\]\s*\$SecurityPayloadOnly'
        $validator | Should -Match 'precommit-security-validation\.json'
        $validator | Should -Match "Add-ValidationCheck -Name 'precommit-security-validation'"
        $validator | Should -Match 'securityPrecommitValidationSha256'
        $buildFunction | Should -Match '(?s)Test-ModUpdateCandidate\.ps1.*?-SecurityPayloadOnly'
        $buildFunction.IndexOf('-SecurityPayloadOnly', [StringComparison]::Ordinal) |
            Should -BeLessThan $buildFunction.IndexOf("@('commit'", [StringComparison]::Ordinal)
    }

    # Scenario: Review completion or its completed-stage fast path is resumed after feedback evidence changes.
    # Purpose: Bind the local Review and independent completion decision to one immutable PR feedback snapshot artifact.
    It 'UnitT204_BindsReviewCompletionToTheImmutableFeedbackSnapshot' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw

        $runner | Should -Match 'reviewSnapshot\s*=\s*\[ordered\]'
        $runner | Should -Match 'feedbackSnapshotSha256'
        $validator | Should -Match "Add-ReviewCheck -Name 'feedback-snapshot'"
        $validator | Should -Match 'review-snapshot\.json'
        $validator | Should -Match '\$review\.feedbackSnapshotSha256'
        $validator | Should -Match 'Feedback snapshot SHA-256 changed'
        $validator | Should -Match 'Local review predates the immutable feedback snapshot'
    }

    # Scenario: A non-localization run can still have security, metadata, or evidence feedback on its PR.
    # Purpose: Capture PR feedback for local Review even when optional external localization Review is not applicable.
    It 'UnitT205_CapturesPrFeedbackWhenLocalizationModeIsNone' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $reviewStart = $runner.IndexOf('function Invoke-ReviewSnapshot', [StringComparison]::Ordinal)
        $reviewEnd = $runner.IndexOf('function Resolve-InitialState', $reviewStart, [StringComparison]::Ordinal)
        $reviewFunction = $runner.Substring($reviewStart, $reviewEnd - $reviewStart)

        $viewIndex = $reviewFunction.IndexOf("'headRefOid,reviews,reviewRequests,comments'", [StringComparison]::Ordinal)
        $noneIndex = $reviewFunction.IndexOf('$State.localizationMode -eq ''none''', [StringComparison]::Ordinal)
        $viewIndex | Should -BeGreaterOrEqual 0
        $noneIndex | Should -BeGreaterThan $viewIndex
        $reviewFunction | Should -Match 'reviewThreads\(first:100\)'
        $reviewFunction | Should -Match '\$snapshot\[''reviewThreads''\]\s*='
        $reviewFunction | Should -Match 'Review feedback snapshot exceeds the bounded thread capacity'
    }

    # Scenario: An untrusted ZIP reaches the documented high-entry boundary without any file/ancestor collision.
    # Purpose: Keep collision validation proportional to path depth instead of comparing every entry with every other entry.
    It 'UnitT206_IndexesArchiveAncestorPrefixesInLinearSpace' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Assert-NoArchiveFileAncestorCollisions'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $seen = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::OrdinalIgnoreCase)
        for ($index = 0; $index -lt 5000; $index++) {
            $seen.Add("ExampleMod/dir-$index/file.lua", $false)
        }
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()

        & $module { param($paths) Assert-NoArchiveFileAncestorCollisions -Seen $paths } $seen

        $stopwatch.Stop()
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 3
        $functionAst.Extent.Text | Should -Match '\$filePaths\s*=\s*\[Collections\.Generic\.HashSet\[string\]\]::new'
        $functionAst.Extent.Text | Should -Not -Match '\$ancestorPrefixes\s*='
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $runner | Should -Not -Match '\$entries\s*\+='
        $runner | Should -Not -Match '(?s)\$seen\.Keys\s*\|\s*Where-Object.*?StartsWith'
    }

    # Scenario: Evidence generation has been consolidated into the bounded batch implementation.
    # Purpose: Prevent a second unused Git evidence implementation from drifting away from the audited path.
    It 'UnitT207_UsesOnlyTheBoundedGitEvidenceImplementation' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Not -Match 'function New-GitEvidenceFile'
        ([regex]::Matches($runner, 'New-GitEvidenceBatch')).Count | Should -Be 2
    }

    # Scenario: Archive and candidate manifests may each contain up to the documented 100,000 payload files.
    # Purpose: Prevent repeated PowerShell array copies from reintroducing quadratic work after ZIP validation.
    It 'UnitT208_UsesLinearCollectionsForHighCardinalityManifestEnumeration' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $validator = Get-Content -LiteralPath $validatorPath -Raw
        $tokens = $null
        $parseErrors = $null
        $runnerAst = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        foreach ($functionName in @('New-Manifest', 'Import-SecurityOverrides', 'New-GitNormalizationManifest', 'New-GitTreeManifest', 'Invoke-Localization')) {
            $functionAst = $runnerAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            $functionAst.Extent.Text | Should -Not -Match '\$[A-Za-z][A-Za-z0-9_]*\s*\+=\s*\[ordered\]'
            if ($functionName -ne 'New-Manifest') {
                $functionAst.Extent.Text | Should -Match 'Collections\.Generic\.List\[object\]'
            }
        }
        $validator | Should -Not -Match '\$actual\s*\+=\s*\[ordered\]'
        $validator | Should -Match '\$actual\s*=\s*\[Collections\.Generic\.List\[object\]\]::new\(\)'
    }

    # Scenario: Any immutable source-tuple field differs between state and the run-local package pin.
    # Purpose: Keep every authorization field fail-closed rather than protecting only pin bytes and commit identity.
    It 'UnitT209_RejectsEveryRunLocalSkillSourceTupleMismatch' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Assert-RunLocalSkillPinRecord'
        }, $true)
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $pin = [ordered]@{
            repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
            requestedRef = 'v0.3.2'
            resolvedCommit = '1' * 40
            resolvedVersion = '0.3.2'
            contentSha256 = 'a' * 64
            pinSha256 = 'b' * 64
        }
        $state = [ordered]@{
            workflowSourceRepository = $pin.repository
            workflowRef = $pin.requestedRef
            workflowCommitOid = $pin.resolvedCommit
            workflowSourceVersion = $pin.resolvedVersion
            workflowSourceContentSha256 = $pin.contentSha256
            workflowSourcePinSha256 = $pin.pinSha256
        }
        $mismatches = [ordered]@{
            workflowSourceRepository = 'https://example.invalid/other.git'
            workflowRef = 'other-ref'
            workflowCommitOid = '2' * 40
            workflowSourceVersion = '9.9.9'
            workflowSourceContentSha256 = 'c' * 64
            workflowSourcePinSha256 = 'd' * 64
        }

        foreach ($field in $mismatches.Keys) {
            $changed = $state | ConvertTo-Json -Depth 10 | ConvertFrom-TestJson -AsHashtable
            $changed[$field] = $mismatches[$field]
            { & $module { param($value, $record) Assert-RunLocalSkillPinRecord -State $value -PinRecord $record -ActualPinSha256 $record.pinSha256 } `
                    $changed $pin } | Should -Throw '*Skill package drift*'
        }
    }

    # Scenario: the Candidate Gate fails once, records status=failed, then passes on a same-run retry.
    # Purpose: Restore the publishable checkpoint state while preserving failed-attempt history in stage timings.
    It 'UnitT210_RepairsTheTopLevelStateAfterACandidateGateRetryPasses' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Repair-SuccessfulCandidateGateState'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        $module = New-Module -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text))
        $state = [ordered]@{
            status = 'failed'
            waitingReason = [ordered]@{ code = 'stale-wait' }
            lastError = [ordered]@{ stage = 'validate'; error = 'first attempt failed' }
            candidateGate = [ordered]@{ status = 'passed' }
            stageTimings = [ordered]@{ validate = [ordered]@{ attempts = @([ordered]@{ result = 'failed' }) } }
        }

        (& $module { param($value) Repair-SuccessfulCandidateGateState -State $value } $state) | Should -BeTrue
        $state.status | Should -Be 'candidate-committed'
        $state.waitingReason | Should -BeNullOrEmpty
        $state.lastError | Should -BeNullOrEmpty
        $state.stageTimings.validate.attempts[0].result | Should -Be 'failed'
    }

    # Scenario: A real ZIP changes an active localization file, including metadata preflight failures and resumable evidence failures.
    # Purpose: Prove fail-closed metadata validation, C0/C1/C2/C3/F recovery, byte preservation, manifests, timings, and rerun idempotency.
    It 'InterT200_ExecutesABytePreservingLocalizedCandidateEndToEnd' {
        $fixtureRepo = Join-Path $TestDrive 'fixture-repository'
        $modRoot = Join-Path $fixtureRepo 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        $queueRoot = Join-Path $fixtureRepo 'AI Auto Update'
        New-Item -ItemType Directory -Path $modRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $queueRoot -Force | Out-Null
        $relativeLocalization = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod/scripts/mods/ExampleMod/ExampleMod_localization.lua'
        $relativeNewLocalization = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod/scripts/mods/ExampleMod/new_localization.lua'
        $relativeRemovedLocalization = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod/scripts/mods/ExampleMod/removed_localization.lua'
        $oldLocalizationPath = Join-Path $fixtureRepo $relativeLocalization
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldLocalizationPath) -Force | Out-Null
        [IO.File]::WriteAllText($oldLocalizationPath, "return { key = `"Old`" }`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $fixtureRepo $relativeRemovedLocalization), "return { removed = `"舊翻譯`" }`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $modRoot 'upstream.txt'), "old`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $fixtureRepo '.gitattributes'), "*.lua text`n*.txt text`n", [Text.UTF8Encoding]::new($false))
        & git -C $fixtureRepo init --quiet --initial-branch=main
        & git -C $fixtureRepo config user.name 'Fixture User'
        & git -C $fixtureRepo config user.email 'fixture@example.invalid'
        & git -C $fixtureRepo add --all
        & git -C $fixtureRepo commit --quiet -m 'fixture baseline'

        $archivePath = Join-Path $queueRoot 'ExampleMod.zip'
        $rawText = "return {`r`n`tkey = `"Hello`",`r`n`tdynamic = `"Dynamic`",`n" + ("`r`n" * 22) + "`t`r`n`ttrail = `"keep`"`t`r`n}"
        $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $localizationEntry = $archive.CreateEntry('ExampleMod/scripts/mods/ExampleMod/ExampleMod_localization.lua')
            $entryStream = $localizationEntry.Open()
            try {
                $rawBytes = [Text.Encoding]::UTF8.GetBytes($rawText)
                $entryStream.Write($rawBytes, 0, $rawBytes.Length)
            }
            finally { $entryStream.Dispose() }
            $newLocalizationText = "return { added = `"New upstream text`" }`r`n"
            $newLocalizationEntry = $archive.CreateEntry('ExampleMod/scripts/mods/ExampleMod/new_localization.lua')
            $entryStream = $newLocalizationEntry.Open()
            try {
                $newLocalizationBytes = [Text.Encoding]::UTF8.GetBytes($newLocalizationText)
                $entryStream.Write($newLocalizationBytes, 0, $newLocalizationBytes.Length)
            }
            finally { $entryStream.Dispose() }
            $upstreamEntry = $archive.CreateEntry('ExampleMod/upstream.txt')
            $entryStream = $upstreamEntry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes("new`r`n")
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally { $entryStream.Dispose() }
        }
        finally { $archive.Dispose(); $archiveStream.Dispose() }

        $manualSourceRequestPath = Join-Path $TestDrive 'manual-source-request.json'
        [ordered]@{
            schemaVersion = 2; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
            pageVersion = '2.0.0'; pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'; mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
        } | ConvertTo-Json | Set-Content -LiteralPath $manualSourceRequestPath -NoNewline
        $manualArchiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manualArchiveSize = (Get-Item -LiteralPath $archivePath).Length
        (@(
            '- Nexus MOD ID: 123', '- Nexus URL: https://www.nexusmods.com/warhammer40kdarktide/mods/123',
            '- Nexus page version: 2.0.0', '- Nexus last updated: 2026-01-02T00:00:00.0000000+00:00',
            '- Main file ID: 456', '- Main file version: 2.0.0',
            '- Main file uploaded at UTC: 2026-01-01T00:00:00.0000000+00:00',
            '- Archive filename: ExampleMod.zip', "- Archive size bytes: $manualArchiveSize",
            "- Archive SHA-256: $manualArchiveSha", '- Acquisition method: manual-queue'
        ) -join "`n") | Set-Content -LiteralPath (Join-Path $fixtureRepo 'README.md') -NoNewline
        $manualHashDirectory = Join-Path $fixtureRepo '.hash'
        New-Item -ItemType Directory -Path $manualHashDirectory -Force | Out-Null
        (@(
            'nexus_id=123', 'nexus_url=https://www.nexusmods.com/warhammer40kdarktide/mods/123',
            'nexus_page_version=2.0.0', 'nexus_last_updated=2026-01-02T00:00:00.0000000+00:00',
            'main_file_id=456', 'version=2.0.0', 'main_file_uploaded_at_utc=2026-01-01T00:00:00.0000000+00:00',
            'filename=ExampleMod.zip', "size_bytes=$manualArchiveSize", "sha256=$manualArchiveSha", 'acquisition_method=manual-queue'
        ) -join "`n") | Set-Content -LiteralPath (Join-Path $manualHashDirectory 'examplemod.hash') -NoNewline
        & git -C $fixtureRepo add README.md .hash/examplemod.hash
        & git -C $fixtureRepo commit --quiet -m 'fixture source metadata'
        $claimWallClock = [Diagnostics.Stopwatch]::StartNew()
        $claim = & $runnerPath claim -RepositoryRoot $fixtureRepo -ArchivePath $archivePath -ModDirectory 'ExampleMod' `
            -SourceRequestPath $manualSourceRequestPath -SkillSourcePinPath $script:skillSourcePinPath -BaseRef HEAD `
            -PassThru
        $claimWallClock.Stop()
        $claim.result | Should -Be 'passed'
        $claim.status | Should -Be 'worktree-ready'
        $claim.stageTimings.stabilityObservationMilliseconds | Should -BeGreaterOrEqual 9000
        $claim.stageTimings.coordinationWaitMilliseconds | Should -BeGreaterOrEqual 0
        $claim.stageTimings.waitingMilliseconds | Should -Be `
            ([int64]$claim.stageTimings.stabilityObservationMilliseconds + [int64]$claim.stageTimings.coordinationWaitMilliseconds)
        ([int64]$claim.stageTimings.activeMilliseconds + [int64]$claim.stageTimings.waitingMilliseconds) |
            Should -Be ([int64]$claim.stageTimings.wallClockMilliseconds)
        [Math]::Abs([int64]$claimWallClock.ElapsedMilliseconds - [int64]$claim.stageTimings.wallClockMilliseconds) |
            Should -BeLessThan 5000
        $statePath = $claim.statePath
        $claimStateAfterExit = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $claimOwner = Get-Content -LiteralPath (Join-Path $claimStateAfterExit.modLockPath 'owner.json') -Raw | ConvertFrom-Json
        $claimOwner.leaseMode | Should -Be 'reserved'
        $claimOwner.workerToken | Should -BeNullOrEmpty
        $claimOwner.workerId | Should -BeNullOrEmpty

        $claimedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        @($claimedState.metadataPaths) | Should -Be @('README.md', '.hash/examplemod.hash')
        $secondArchivePath = Join-Path $queueRoot 'ExampleMod-second.zip'
        [IO.File]::Copy($claimedState.archive.path, $secondArchivePath)
        $secondSourceRequestPath = Join-Path $TestDrive 'manual-source-request-second.json'
        $secondSourceRequest = Get-Content -LiteralPath $manualSourceRequestPath -Raw | ConvertFrom-TestJson
        $secondSourceRequest.fileName = 'ExampleMod-second.zip'
        $secondSourceRequest | ConvertTo-Json | Set-Content -LiteralPath $secondSourceRequestPath -NoNewline
        { & $runnerPath claim -RepositoryRoot $fixtureRepo -ArchivePath $secondArchivePath -ModDirectory 'ExampleMod' `
                -SourceRequestPath $secondSourceRequestPath -SkillSourcePinPath $script:skillSourcePinPath -BaseRef HEAD -PassThru } |
            Should -Throw '*already owns this canonical MOD identity*'
        Test-Path -LiteralPath $secondArchivePath -PathType Leaf | Should -Be $true
        [IO.File]::Delete($secondArchivePath)

        $incompleteClaim = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $incompleteClaim.status = 'claiming'
        $incompleteClaim.completedStages = @($incompleteClaim.completedStages | Where-Object { $_ -ne 'claim' })
        $incompleteClaim.stageTimings.Remove('claim')
        $incompleteClaim.archive.originalPath | Should -Not -BeNullOrEmpty
        [IO.File]::Move([string]$incompleteClaim.archive.path, [string]$incompleteClaim.archive.originalPath)
        [IO.File]::WriteAllText($statePath, ($incompleteClaim | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $claimRecovery = & $runnerPath claim -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $claimRecovery.result | Should -Be 'passed'
        Test-Path -LiteralPath $incompleteClaim.archive.originalPath | Should -Be $false
        Test-Path -LiteralPath $incompleteClaim.archive.path -PathType Leaf | Should -Be $true
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).lastRecovery.reason | Should -Be 'incomplete claim reattached to original run tuple'

        $writerState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $writerLockPath = Join-Path $writerState.runRoot '.writer.lock'
        $liveWriter = [ordered]@{
            schemaVersion = 1; runId = $writerState.runId; statePath = $statePath; token = [guid]::NewGuid().ToString()
            machineName = [Environment]::MachineName; processId = $PID
            processStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks; acquiredAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText($writerLockPath, ($liveWriter | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        { & $runnerPath verify-source -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*active single writer*'
        [IO.File]::Delete($writerLockPath)
        $staleWriter = $liveWriter
        $staleWriter.processId = 2147483000
        $staleWriter.processStartTicks = 1
        [IO.File]::WriteAllText($writerLockPath, ($staleWriter | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        (& $runnerPath verify-source -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).result | Should -Be 'passed'
        $writerRecoveryState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $writerRecoveryState.lastRecovery.reason | Should -Be 'stale run writer lock retained'
        Test-Path -LiteralPath $writerRecoveryState.lastRecovery.retainedPath -PathType Leaf | Should -Be $true
        $preExtractState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $archiveBackupPath = Join-Path $preExtractState.runRoot 'archive-before-tamper.zip'
        [IO.File]::Copy([string]$preExtractState.archive.path, $archiveBackupPath)
        try {
            $appendStream = [IO.File]::Open([string]$preExtractState.archive.path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $appendStream.WriteByte(0) } finally { $appendStream.Dispose() }
            { & $runnerPath extract -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
                Should -Throw '*Claimed archive SHA-256 changed before ZIP processing*'
        }
        finally {
            [IO.File]::Copy($archiveBackupPath, [string]$preExtractState.archive.path, $true)
        }
        $partialExtraction = Join-Path $preExtractState.runRoot 'staging/extracted'
        New-Item -ItemType Directory -Path $partialExtraction -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $partialExtraction 'partial.txt'), 'crash residue', [Text.UTF8Encoding]::new($false))
        (& $runnerPath extract -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).result | Should -Be 'passed'

        $preInstallState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $worktreeModRoot = Join-Path ([string]$preInstallState.worktreePath) 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        $outsideInstallTarget = Join-Path $TestDrive 'install-junction-target'
        Move-Item -LiteralPath $worktreeModRoot -Destination $outsideInstallTarget
        New-Item -ItemType Junction -Path $worktreeModRoot -Target $outsideInstallTarget | Out-Null
        try {
            { & $runnerPath install -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
                Should -Throw '*reparse*'
            Test-Path -LiteralPath (Join-Path $outsideInstallTarget 'upstream.txt') -PathType Leaf | Should -Be $true
        }
        finally {
            if (Test-Path -LiteralPath $worktreeModRoot) {
                $installedItem = Get-Item -LiteralPath $worktreeModRoot -Force
                if ($installedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    Remove-Item -LiteralPath $worktreeModRoot -Force
                }
                else {
                    Remove-Item -LiteralPath $worktreeModRoot -Recurse -Force
                }
            }
            Move-Item -LiteralPath $outsideInstallTarget -Destination $worktreeModRoot
        }
        (& $runnerPath install -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).result | Should -Be 'passed'

        $indexedText = $rawText.Replace("`r`n", "`n")
        $indexedBytes = [Text.Encoding]::UTF8.GetBytes($indexedText)
        $helloCharacterOffset = $indexedText.IndexOf('Hello', [StringComparison]::Ordinal)
        $helloByteOffset = [Text.Encoding]::UTF8.GetByteCount($indexedText.Substring(0, $helloCharacterOffset))
        $oldBytes = [Text.Encoding]::UTF8.GetBytes('Hello')
        $replacementBytes = [Text.Encoding]::UTF8.GetBytes('你好')
        $dynamicCharacterOffset = $indexedText.IndexOf('Dynamic', [StringComparison]::Ordinal)
        $dynamicByteOffset = [Text.Encoding]::UTF8.GetByteCount($indexedText.Substring(0, $dynamicCharacterOffset))
        $dynamicOldBytes = [Text.Encoding]::UTF8.GetBytes('Dynamic')
        $dynamicReplacementBytes = [Text.Encoding]::UTF8.GetBytes('動態')
        $newIndexedBytes = [Text.Encoding]::UTF8.GetBytes($newLocalizationText.Replace("`r`n", "`n"))
        $planPath = Join-Path $TestDrive 'localization-plan.json'
        $plan = [ordered]@{
            schemaVersion = 1
            mode = 'zh-tw'
            files = @(
                [ordered]@{
                    relativePath = $relativeLocalization
                    indexedSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($indexedBytes)).ToLowerInvariant()
                    approvedSpans = @(
                        [ordered]@{
                            startByte = $helloByteOffset
                            length = $oldBytes.Length
                            oldSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($oldBytes)).ToLowerInvariant()
                            replacementBase64 = [Convert]::ToBase64String($replacementBytes)
                        },
                        [ordered]@{
                            startByte = $dynamicByteOffset
                            length = $dynamicOldBytes.Length
                            oldSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($dynamicOldBytes)).ToLowerInvariant()
                            replacementBase64 = [Convert]::ToBase64String($dynamicReplacementBytes)
                        }
                    )
                },
                [ordered]@{
                    relativePath = $relativeNewLocalization
                    indexedSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($newIndexedBytes)).ToLowerInvariant()
                    approvedSpans = @()
                }
            )
            removedPaths = @($relativeRemovedLocalization)
        }
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $localization = & $runnerPath localization -RepositoryRoot $fixtureRepo -StatePath $statePath -LocalizationPlanPath $planPath -PassThru
        $localization.result | Should -Be 'passed'
        $localization.status | Should -Be 'localized'
        $localizedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        [string]$localizedState.status | Should -Be 'localized'
        @($localizedState.completedStages) | Should -Contain 'localization'
        $localizationArtifactSha = [string]$localizedState.stageTimings.localization.artifactSha256
        $localizedState.status = 'installed'
        [IO.File]::WriteAllText($statePath, ($localizedState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $localizationRecovery = & $runnerPath localization -RepositoryRoot $fixtureRepo -StatePath $statePath -LocalizationPlanPath $planPath -PassThru
        $localizationRecovery.result | Should -Be 'passed'
        $localizationRecovery.idempotent | Should -BeTrue
        $localizationRecovery.status | Should -Be 'localized'
        $recoveredLocalizationState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        [string]$recoveredLocalizationState.status | Should -Be 'localized'
        [string]$recoveredLocalizationState.stageTimings.localization.artifactSha256 | Should -Be $localizationArtifactSha
        @($recoveredLocalizationState.completedStages | Where-Object { $_ -ceq 'localization' }).Count | Should -Be 1

        $unexpectedInstallPath = Join-Path ([string]$recoveredLocalizationState.installRoot) 'unexpected-after-install.txt'
        [IO.File]::WriteAllText($unexpectedInstallPath, 'not from the verified archive', [Text.UTF8Encoding]::new($false))
        $remoteTrackingRef = "refs/remotes/$($recoveredLocalizationState.remote)/$($recoveredLocalizationState.branch)"
        & git -C $recoveredLocalizationState.worktreePath show-ref --verify --quiet $remoteTrackingRef
        $LASTEXITCODE | Should -Be 1
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*Pre-C1 raw install tree file count differs from its immutable manifest*'
        $installDriftState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        (& git -C $installDriftState.worktreePath rev-parse HEAD).Trim() | Should -Be $installDriftState.evidenceChain.c0Oid
        $installDriftState.evidenceChain.c1Oid | Should -BeNullOrEmpty
        [IO.File]::Delete($unexpectedInstallPath)

        $attributesPath = Join-Path ([string]$recoveredLocalizationState.worktreePath) '.gitattributes'
        $attributesBytes = [IO.File]::ReadAllBytes($attributesPath)
        [IO.File]::AppendAllText($attributesPath, "upstream.txt -text`n", [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*C1 index blob differs from its immutable expected SHA-256*'
        $attributeDriftState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        (& git -C $attributeDriftState.worktreePath rev-parse HEAD).Trim() | Should -Be $attributeDriftState.evidenceChain.c0Oid
        $attributeDriftState.evidenceChain.c1Oid | Should -BeNullOrEmpty
        [IO.File]::WriteAllBytes($attributesPath, $attributesBytes)

        $metadataReadmePath = Join-Path ([string]$recoveredLocalizationState.worktreePath) 'README.md'
        $metadataReadmeBytes = [IO.File]::ReadAllBytes($metadataReadmePath)
        $metadataReadmeText = [Text.Encoding]::UTF8.GetString($metadataReadmeBytes)
        $metadataReadmeText = $metadataReadmeText.Replace(
            '- Nexus page version: 2.0.0',
            '- Nexus page version: incorrect-version'
        )
        [IO.File]::WriteAllText($metadataReadmePath, $metadataReadmeText, [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*Metadata preflight field mismatch: README.md nexusPageVersion*'
        $metadataMismatchState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        (& git -C $metadataMismatchState.worktreePath rev-parse HEAD).Trim() | Should -Be $metadataMismatchState.evidenceChain.c0Oid
        $metadataMismatchState.evidenceChain.c1Oid | Should -BeNullOrEmpty
        [IO.File]::WriteAllBytes($metadataReadmePath, $metadataReadmeBytes)

        $metadataHashPath = Join-Path ([string]$recoveredLocalizationState.worktreePath) '.hash/examplemod.hash'
        $metadataHashBytes = [IO.File]::ReadAllBytes($metadataHashPath)
        [IO.File]::Delete($metadataHashPath)
        $metadataWaiting = & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $metadataWaiting.result | Should -Be 'waiting-input'
        $metadataWaiting.stage | Should -Be 'metadata-preparation'
        @($metadataWaiting.data.missingPaths) | Should -Be @('.hash/examplemod.hash')
        [string]$metadataWaiting.data.sourceTupleSha256 | Should -Be ([string]$recoveredLocalizationState.sourceTuple.sha256)
        $metadataFailureState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        (& git -C $metadataFailureState.worktreePath rev-parse HEAD).Trim() | Should -Be $metadataFailureState.evidenceChain.c0Oid
        $metadataFailureState.evidenceChain.c1Oid | Should -BeNullOrEmpty
        $metadataFailureState.status | Should -Be 'waiting-input'
        $metadataFailureState.stageTimings.'build-commits'.result | Should -Be 'waiting-input'
        $metadataFailureState.waitingReason.code | Should -Be 'metadata_preparation_required'
        [IO.File]::WriteAllBytes($metadataHashPath, $metadataHashBytes)

        $c1FailureState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $expectedIndexedSha = [string]$c1FailureState.localizationFiles[0].indexedSha256
        $c1FailureState.localizationFiles[0].indexedSha256 = '0' * 64
        [IO.File]::WriteAllText($statePath, ($c1FailureState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*C2 index bytes do not match*'
        $recordedC1State = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $recordedC1State.evidenceChain.c1Oid | Should -Match '^[0-9a-f]{40}$'
        $recordedC1State.evidenceChain.c2Oid | Should -BeNullOrEmpty
        $recordedC1State.waitingReason | Should -BeNullOrEmpty
        $recordedC1State.buildCommitsRecovery.partialCheckpoint | Should -Be 'c1'
        $recordedC1State.buildCommitsRecovery.recoveryDisposition | Should -Be 'same-run-checkpoint-resume'

        $partialReadmeBytes = [IO.File]::ReadAllBytes($metadataReadmePath)
        [IO.File]::AppendAllText($metadataReadmePath, "`nUnrelated metadata drift", [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*Metadata preview inputs changed after build-commits preflight*'
        $metadataDriftState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        (& git -C $metadataDriftState.worktreePath rev-parse HEAD).Trim() | Should -Be $recordedC1State.evidenceChain.c1Oid
        [IO.File]::WriteAllBytes($metadataReadmePath, $partialReadmeBytes)

        $metadataDriftState.localizationFiles[0].indexedSha256 = $expectedIndexedSha
        [IO.File]::WriteAllText($statePath, ($metadataDriftState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))

        $gitEvidenceBlocker = Join-Path ([string]$recordedC1State.artifactsRoot) 'git-evidence'
        [IO.File]::WriteAllText($gitEvidenceBlocker, 'block evidence directory creation', [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } | Should -Throw
        $recordedC3State = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $recordedC3State.evidenceChain.c3Oid | Should -Match '^[0-9a-f]{40}$' -Because ([string]$recordedC3State.lastError.error)
        $recordedC3State.evidenceChain.fOid | Should -Match '^[0-9a-f]{40}$' -Because ([string]$recordedC3State.lastError.error)
        $recordedC3State.buildCommitsRecovery.partialCheckpoint | Should -Be 'f'
        $recordedC3State.buildCommitsRecovery.recoveryDisposition | Should -Be 'same-run-checkpoint-resume'
        [IO.File]::Delete($gitEvidenceBlocker)

        $resumedBuild = & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $resumedBuild.result | Should -Be 'passed'
        $resumedBuild.stageTimings.attempts.Count | Should -Be 8
        @($resumedBuild.stageTimings.attempts | Where-Object result -eq 'failed').Count | Should -Be 6
        @($resumedBuild.stageTimings.attempts | Where-Object result -eq 'waiting-input').Count | Should -Be 1
        $resumedBuild.stageTimings.attempts[-1].result | Should -Be 'passed'
        $preGateState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $rawEvidenceStart = [Diagnostics.ProcessStartInfo]::new()
        $rawEvidenceStart.FileName = 'git'
        $rawEvidenceStart.UseShellExecute = $false
        $rawEvidenceStart.RedirectStandardOutput = $true
        $rawEvidenceStart.RedirectStandardError = $true
        foreach ($argument in @(
            '-C', [string]$preGateState.worktreePath, 'diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames',
            "$($preGateState.evidenceChain.c0Oid)..$($preGateState.evidenceChain.c1Oid)"
        )) { $rawEvidenceStart.ArgumentList.Add($argument) }
        $rawEvidenceProcess = [Diagnostics.Process]::new()
        $rawEvidenceProcess.StartInfo = $rawEvidenceStart
        $rawEvidenceMemory = [IO.MemoryStream]::new()
        try {
            $rawEvidenceProcess.Start() | Should -BeTrue
            $rawEvidenceCopy = $rawEvidenceProcess.StandardOutput.BaseStream.CopyToAsync($rawEvidenceMemory)
            $rawEvidenceError = $rawEvidenceProcess.StandardError.ReadToEndAsync()
            $rawEvidenceProcess.WaitForExit()
            $rawEvidenceCopy.GetAwaiter().GetResult()
            $rawEvidenceError.GetAwaiter().GetResult() | Should -BeNullOrEmpty
            $rawEvidenceProcess.ExitCode | Should -Be 0
            [IO.File]::ReadAllBytes([string]$preGateState.evidenceDiffs.c0C1Diff.path) |
                Should -Be $rawEvidenceMemory.ToArray()
        }
        finally {
            $rawEvidenceMemory.Dispose()
            $rawEvidenceProcess.Dispose()
        }
        try {
            $appendStream = [IO.File]::Open([string]$preGateState.archive.path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $appendStream.WriteByte(0) } finally { $appendStream.Dispose() }
            { & $validatorPath -StatePath $statePath -PassThru } | Should -Throw '*claimed-archive*'
            (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).candidateGate.status | Should -Be 'rejected'
        }
        finally {
            [IO.File]::Copy($archiveBackupPath, [string]$preGateState.archive.path, $true)
        }
        $validation = & $runnerPath validate -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $validation.result | Should -Be 'passed'

        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $state.candidateGate.status | Should -Be 'passed'
        $state.sourceTuple.contract.acquisitionMethod | Should -Be 'manual-queue'
        $state.sourceTuple.contract.archive.fileName | Should -Be 'ExampleMod.zip'
        $state.metadataPreview.sourceTupleContractSha256 | Should -Be $state.sourceTuple.contractSha256
        $evidenceReceipt = Get-Content -LiteralPath $state.evidenceReceipt.path -Raw | ConvertFrom-TestJson -AsHashtable
        $evidenceReceipt.schemaVersion | Should -Be 2
        $evidenceReceipt.executionMode | Should -Be 'bounded-parallel'
        $evidenceReceipt.maxConcurrency | Should -Be 4
        @($evidenceReceipt.tasks).Count | Should -BeGreaterThan 4
        $evidenceReceipt.coordinatorVerification.result | Should -Be 'passed'
        foreach ($task in @($evidenceReceipt.tasks)) {
            foreach ($field in @('name', 'baseOid', 'headOid', 'treeOid', 'artifact', 'startedAt', 'completedAt')) {
                $task.Contains($field) | Should -BeTrue
            }
            $task.artifact.size | Should -BeGreaterOrEqual 0
            $task.artifact.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
        foreach ($field in @('c0Oid', 'c1Oid', 'c2Oid', 'c3Oid', 'fOid', 'c0TreeOid', 'c1TreeOid', 'c2TreeOid', 'c3TreeOid', 'fTreeOid')) {
            $state.evidenceChain[$field] | Should -Match '^[0-9a-f]{40}$'
        }

        $metadataPreviewBytes = [IO.File]::ReadAllBytes([string]$state.metadataPreview.path)
        $metadataPreviewStateBytes = [IO.File]::ReadAllBytes($statePath)
        try {
            $metadataPreview = Get-Content -LiteralPath $state.metadataPreview.path -Raw | ConvertFrom-TestJson -AsHashtable
            $metadataPreview.files[0].indexedSha256 = '0' * 64
            [IO.File]::WriteAllText([string]$state.metadataPreview.path, ($metadataPreview | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
            $metadataTamperState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
            $metadataTamperState.metadataPreview.sha256 = (Get-FileHash -LiteralPath $metadataTamperState.metadataPreview.path -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($statePath, ($metadataTamperState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
            { & $validatorPath -StatePath $statePath -PassThru } | Should -Throw '*metadata-preview-index*'
        }
        finally {
            [IO.File]::WriteAllBytes([string]$state.metadataPreview.path, $metadataPreviewBytes)
            [IO.File]::WriteAllBytes($statePath, $metadataPreviewStateBytes)
        }

        $evidenceReceiptBytes = [IO.File]::ReadAllBytes([string]$state.evidenceReceipt.path)
        $evidenceReceiptStateBytes = [IO.File]::ReadAllBytes($statePath)
        try {
            $tamperedReceipt = Get-Content -LiteralPath $state.evidenceReceipt.path -Raw | ConvertFrom-TestJson -AsHashtable
            $tamperedReceipt.inputTupleSha256 = '0' * 64
            [IO.File]::WriteAllText([string]$state.evidenceReceipt.path, ($tamperedReceipt | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
            $receiptTamperState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
            $receiptTamperState.evidenceReceipt.sha256 = (Get-FileHash -LiteralPath $receiptTamperState.evidenceReceipt.path -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText($statePath, ($receiptTamperState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
            { & $validatorPath -StatePath $statePath -PassThru } | Should -Throw '*evidence-generation-receipt*'
        }
        finally {
            [IO.File]::WriteAllBytes([string]$state.evidenceReceipt.path, $evidenceReceiptBytes)
            [IO.File]::WriteAllBytes($statePath, $evidenceReceiptStateBytes)
        }
        $expectedMerged = $indexedText.Replace('Hello', '你好').Replace('Dynamic', '動態')
        $finalLocalizationPath = Join-Path $state.worktreePath $relativeLocalization
        $finalBytes = [IO.File]::ReadAllBytes($finalLocalizationPath)
        $finalBytes | Should -Be ([Text.Encoding]::UTF8.GetBytes($expectedMerged))
        $finalText = [Text.Encoding]::UTF8.GetString($finalBytes)
        @($finalText -split "`n" | Where-Object { $_ -ceq '' }).Count | Should -Be 22
        $finalText | Should -Match "`n`t`n"
        $finalText.Contains("keep`"`t`n") | Should -Be $true
        $finalText | Should -Match 'dynamic = "動態"'
        $finalText | Should -Not -Match "`r"
        $finalBytes[-1] | Should -Be ([byte][char]'}')
        [IO.File]::ReadAllBytes((Join-Path $state.worktreePath $relativeNewLocalization)) | Should -Be $newIndexedBytes
        Test-Path -LiteralPath (Join-Path $state.worktreePath $relativeRemovedLocalization) | Should -Be $false
        $c1C2NameStatus = Get-Content -LiteralPath $state.evidenceDiffs.c1C2NameStatus.path -Raw
        $c1C2NameStatus | Should -Match "(?m)^A\s+$([regex]::Escape($relativeNewLocalization))\r?$"
        $c1C2NameStatus | Should -Match "(?m)^D\s+$([regex]::Escape($relativeRemovedLocalization))\r?$"
        $state.lastRecovery.reason | Should -Be 'incomplete extract replaced'
        Test-Path -LiteralPath $state.lastRecovery.retainedPath -PathType Container | Should -Be $true
        $newArtifact = Join-Path $state.localizationFiles[0].artifactDirectory 'new.lua'
        [IO.File]::ReadAllBytes($newArtifact) | Should -Be ([Text.Encoding]::UTF8.GetBytes($rawText))
        $decisionsPath = Join-Path $state.localizationFiles[0].artifactDirectory 'decisions.json'
        $decisionsBytes = [IO.File]::ReadAllBytes($decisionsPath)
        [IO.File]::WriteAllText($decisionsPath, '{"approvedSpans":[]}', [Text.UTF8Encoding]::new($false))
        { & $validatorPath -StatePath $statePath -PassThru } | Should -Throw '*decisions artifact SHA-256 changed*'
        [IO.File]::WriteAllBytes($decisionsPath, $decisionsBytes)
        (& $validatorPath -StatePath $statePath -PassThru).result | Should -Be 'passed'

        $installManifest = Get-Content -LiteralPath $state.installManifest.path -Raw | ConvertFrom-Json -AsHashtable
        $localizationManifestEntry = @($installManifest.files | Where-Object { $_.path -eq 'scripts/mods/ExampleMod/ExampleMod_localization.lua' })
        $localizationManifestEntry.Count | Should -Be 1
        $localizationManifestEntry[0].sha256 | Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($finalBytes)).ToLowerInvariant())

        foreach ($stageName in @('claim', 'verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate')) {
            $state.stageTimings[$stageName].result | Should -Be 'passed'
            $state.stageTimings[$stageName].waitingMilliseconds | Should -BeGreaterOrEqual 0
            ([int64]$state.stageTimings[$stageName].activeMilliseconds + [int64]$state.stageTimings[$stageName].waitingMilliseconds) |
                Should -Be ([int64]$state.stageTimings[$stageName].wallClockMilliseconds)
            $state.stageTimings[$stageName].artifactSha256 | Should -Match '^[0-9a-f]{64}$'
        }
        $headBeforeRerun = (& git -C $state.worktreePath rev-parse HEAD).Trim()
        (& $runnerPath claim -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).idempotent | Should -Be $true
        (& $runnerPath install -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).idempotent | Should -Be $true
        $rerun = & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $rerun.idempotent | Should -Be $true
        (& git -C $state.worktreePath rev-parse HEAD).Trim() | Should -Be $headBeforeRerun

        $stateBytesBeforePinDrift = [IO.File]::ReadAllBytes($statePath)
        $ownerPath = Join-Path ([string]$state.modLockPath) 'owner.json'
        $ownerBytesBeforePinDrift = [IO.File]::ReadAllBytes($ownerPath)
        $sourceBytesBeforePinDrift = [IO.File]::ReadAllBytes([string]$state.archive.path)
        $runPinBytes = [IO.File]::ReadAllBytes([string]$state.workflowSourcePinPath)
        try {
            [IO.File]::AppendAllText([string]$state.workflowSourcePinPath, ' ', [Text.UTF8Encoding]::new($false))
            { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
                Should -Throw '*Skill package drift*'
            [IO.File]::ReadAllBytes($statePath) | Should -Be $stateBytesBeforePinDrift
            [IO.File]::ReadAllBytes($ownerPath) | Should -Be $ownerBytesBeforePinDrift
            [IO.File]::ReadAllBytes([string]$state.archive.path) | Should -Be $sourceBytesBeforePinDrift
        }
        finally {
            [IO.File]::WriteAllBytes([string]$state.workflowSourcePinPath, $runPinBytes)
        }

        $receiptBytes = [IO.File]::ReadAllBytes($state.evidenceReceipt.path)
        Remove-Item -LiteralPath $state.evidenceReceipt.path
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*missing its recorded artifact*'
        [IO.File]::WriteAllBytes($state.evidenceReceipt.path, $receiptBytes)

        $incompleteBuildState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $incompleteBuildState.published = $false
        $incompleteBuildState.completedStages = @($incompleteBuildState.completedStages | Where-Object { $_ -ne 'build-commits' })
        $incompleteBuildState.Remove('buildCommitsRecovery')
        [IO.File]::WriteAllText($statePath, ($incompleteBuildState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*Recorded partial HEAD is not bound to the saved build-commits recovery evidence*'
        (& git -C $state.worktreePath rev-parse HEAD).Trim() | Should -Be $headBeforeRerun

        & git -C $state.worktreePath update-ref $remoteTrackingRef $headBeforeRerun
        $LASTEXITCODE | Should -Be 0
        $unpublishedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $evidenceChainBeforeRepair = $unpublishedState.evidenceChain | ConvertTo-Json -Depth 20 -Compress
        $completedStagesBeforeRepair = @($unpublishedState.completedStages)
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*state said unpublished*remote-tracking branch already exists*'
        $repairedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $repairedState.published | Should -BeTrue
        $repairedState.headOid | Should -Be $headBeforeRerun
        ($repairedState.evidenceChain | ConvertTo-Json -Depth 20 -Compress) | Should -Be $evidenceChainBeforeRepair
        @($repairedState.completedStages) | Should -Be $completedStagesBeforeRepair
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*append-only*'

        $baseMismatchState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $baseMismatchState.baseOid = $baseMismatchState.evidenceChain.c1Oid
        [IO.File]::WriteAllText($statePath, ($baseMismatchState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        { & $validatorPath -StatePath $statePath -PassThru } |
            Should -Throw '*base-c0-identity*State base OID differs from C0*'
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).candidateGate.status | Should -Be 'rejected'

        $tamperState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $tamperState.baseOid = $tamperState.evidenceChain.c0Oid
        $tamperState.published = $false
        $tamperState.status = 'candidate-committed'
        $tamperState.completedStages = @($tamperState.completedStages + 'build-commits' | Sort-Object -Unique)
        [IO.File]::WriteAllText($statePath, ($tamperState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $tamperedBytes = [IO.File]::ReadAllBytes($finalLocalizationPath)
        $tamperedBytes[0] = $tamperedBytes[0] -bxor 1
        [IO.File]::WriteAllBytes($finalLocalizationPath, $tamperedBytes)
        { & $validatorPath -StatePath $statePath -PassThru } | Should -Throw '*rejected*'
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).candidateGate.status | Should -Be 'rejected'
    }

    # Scenario: A claimed ZIP uses a traversal path even though its state and identity lock otherwise match.
    # Purpose: Execute the hostile archive boundary and prove verification fails before extraction.
    It 'InterT210_RejectsArchivePathTraversalBeforeExtraction' {
        $runId = [guid]::NewGuid().ToString()
        $short = $runId.Replace('-', '').Substring(0, 8)
        $runRoot = Join-Path $TestDrive "AI Auto Update/In Progress/examplemod-$short"
        $artifactsRoot = Join-Path $runRoot 'artifacts'
        $modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant()))).ToLowerInvariant()
        $lockPath = Join-Path $TestDrive "AI Auto Update/In Progress/.locks/mod/$lockKey.lock"
        New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $lockPath -Force | Out-Null
        $archivePath = Join-Path $runRoot 'hostile.zip'
        $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $archive.CreateEntry('ExampleMod/../../escape.lua')
            $entryStream = $entry.Open()
            try { $entryStream.WriteByte(65) } finally { $entryStream.Dispose() }
        }
        finally { $archive.Dispose(); $archiveStream.Dispose() }
        $statePath = Join-Path $runRoot 'state.json'
        $state = [ordered]@{
            schemaVersion = 14
            runId = $runId
            statePath = $statePath
            repositoryRoot = $TestDrive
            status = 'worktree-ready'
            runRoot = $runRoot
            artifactsRoot = $artifactsRoot
            modLockPath = $lockPath
            modLockKey = $lockKey
            mod = 'ExampleMod'
            repoModDirectory = 'ExampleMod'
            modRelativePath = $modRelativePath
            archive = [ordered]@{
                path = $archivePath
                sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            completedStages = @()
            stageTimings = [ordered]@{}
        }
        $null = Set-TestRunSkillSourcePin -State $state -SourcePinPath $script:skillSourcePinPath
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $owner = [ordered]@{
            schemaVersion = 2
            runId = $runId; canonicalModRelativePath = $modRelativePath; modLockKey = $lockKey
            plannedStatePath = $statePath; statePath = $statePath
            reservationToken = [guid]::NewGuid().ToString('N'); workerToken = $null
            machineName = $null; workerId = $null; workerProcessStartTicks = $null
            leaseMode = 'reserved'; reservationState = 'between-stages'; heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText((Join-Path $lockPath 'owner.json'), ($owner | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        { & $runnerPath verify-source -RepositoryRoot $TestDrive -StatePath $statePath -PassThru } |
            Should -Throw '*path traversal*'
        $failedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        $failedState.status | Should -Be 'waiting-user'
        $failedState.lastError.stage | Should -Be 'verify-source'
        $failedState.stageTimings.'verify-source'.result | Should -Be 'failed'
        $failedState.stageTimings.'verify-source'.attempt | Should -Be 1
        $failedState.stageTimings.'verify-source'.attempts.Count | Should -Be 1
        ([int64]$failedState.stageTimings.'verify-source'.activeMilliseconds +
            [int64]$failedState.stageTimings.'verify-source'.waitingMilliseconds) |
            Should -Be ([int64]$failedState.stageTimings.'verify-source'.wallClockMilliseconds)
        Test-Path -LiteralPath (Join-Path $runRoot 'staging/extracted') | Should -Be $false
    }

    # Scenario: A ZIP has the wrong canonical root, unsafe entry types, reserved names, or file/ancestor collisions.
    # Purpose: Execute identity, link/reparse/special-type, device-path, and normalized collision blocks before extraction.
    It 'InterT220_RejectsInvalidRootSymlinkAndDeviceNameArchives' {
        foreach ($case in @('invalid-root', 'symlink', 'reparse-point', 'unix-special', 'reserved-device', 'file-ancestor-collision')) {
            $runId = [guid]::NewGuid().ToString()
            $short = $runId.Replace('-', '').Substring(0, 8)
            $runRoot = Join-Path $TestDrive "AI Auto Update/In Progress/examplemod-$short"
            $artifactsRoot = Join-Path $runRoot 'artifacts'
            $modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
            $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant()))).ToLowerInvariant()
            $lockPath = Join-Path $TestDrive "AI Auto Update/In Progress/.locks/mod/$lockKey.lock"
            New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $lockPath -Force | Out-Null
            $archivePath = Join-Path $runRoot "$case.zip"
            $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
            $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entryName = switch ($case) {
                    'invalid-root' { 'OtherMod/file.lua' }
                    'symlink' { 'ExampleMod/link.lua' }
                    'reparse-point' { 'ExampleMod/reparse.lua' }
                    'unix-special' { 'ExampleMod/fifo.lua' }
                    'reserved-device' { 'ExampleMod/NUL' }
                    'file-ancestor-collision' { 'ExampleMod/node' }
                }
                $entry = $archive.CreateEntry($entryName)
                if ($case -eq 'symlink') { $entry.ExternalAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2684354560), 0) }
                if ($case -eq 'reparse-point') { $entry.ExternalAttributes = [int][IO.FileAttributes]::ReparsePoint }
                if ($case -eq 'unix-special') { $entry.ExternalAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]268435456), 0) }
                $entryStream = $entry.Open()
                try { $entryStream.WriteByte(65) } finally { $entryStream.Dispose() }
                if ($case -eq 'file-ancestor-collision') {
                    $child = $archive.CreateEntry('ExampleMod/node/child.lua')
                    $childStream = $child.Open()
                    try { $childStream.WriteByte(66) } finally { $childStream.Dispose() }
                }
            }
            finally { $archive.Dispose(); $archiveStream.Dispose() }

            $statePath = Join-Path $runRoot 'state.json'
            $state = [ordered]@{
                schemaVersion = 14
                runId = $runId; statePath = $statePath; repositoryRoot = $TestDrive; status = 'worktree-ready'; runRoot = $runRoot
                artifactsRoot = $artifactsRoot; mod = 'ExampleMod'; modLockPath = $lockPath; modLockKey = $lockKey
                repoModDirectory = 'ExampleMod'; modRelativePath = $modRelativePath
                archive = [ordered]@{ path = $archivePath; sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() }
                completedStages = @(); stageTimings = [ordered]@{}
            }
            $null = Set-TestRunSkillSourcePin -State $state -SourcePinPath $script:skillSourcePinPath
            [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            $owner = [ordered]@{
                schemaVersion = 2
                runId = $runId; canonicalModRelativePath = $modRelativePath; modLockKey = $lockKey
                plannedStatePath = $statePath; statePath = $statePath
                reservationToken = [guid]::NewGuid().ToString('N'); workerToken = $null
                machineName = $null; workerId = $null; workerProcessStartTicks = $null
                leaseMode = 'reserved'; reservationState = 'between-stages'; heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
            }
            [IO.File]::WriteAllText((Join-Path $lockPath 'owner.json'), ($owner | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $expected = switch ($case) {
                'invalid-root' { '*Invalid archive root*' }
                'symlink' { '*symlink rejected*' }
                'reparse-point' { '*reparse point rejected*' }
                'unix-special' { '*special entry type rejected*' }
                'reserved-device' { '*reserved Windows device name*' }
                'file-ancestor-collision' { '*file/ancestor archive path collision rejected*' }
            }
            { & $runnerPath verify-source -RepositoryRoot $TestDrive -StatePath $statePath -PassThru } | Should -Throw $expected
            Test-Path -LiteralPath (Join-Path $runRoot 'staging/extracted') | Should -Be $false
        }
    }

    # Scenario: A valid ZIP introduces a DLL that did not exist at C0.
    # Purpose: Require one exact archive/path/file-SHA approval and record that disposition in extraction evidence.
    It 'InterT221_RequiresAnExactApprovalForAChangedRiskyPayload' {
        $repository = Join-Path $TestDrive 'payload-security-repository'
        $runId = '56565656-6666-4777-8888-999999999999'
        $modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant()))).ToLowerInvariant()
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/examplemod-56565656'
        $artifactsRoot = Join-Path $runRoot 'artifacts'
        $lockPath = Join-Path $repository "AI Auto Update/In Progress/.locks/mod/$lockKey.lock"
        New-Item -ItemType Directory -Path $artifactsRoot, $lockPath, (Join-Path $runRoot 'source'), (Join-Path $repository $modRelativePath) -Force | Out-Null
        & git -C $repository init --quiet --initial-branch=main
        & git -C $repository config user.name 'Fixture User'
        & git -C $repository config user.email 'fixture@example.invalid'
        [IO.File]::WriteAllText((Join-Path $repository $modRelativePath 'existing.lua'), "return {}`n", [Text.UTF8Encoding]::new($false))
        & git -C $repository add -- $modRelativePath
        & git -C $repository commit --quiet -m 'base'
        $c0 = (& git -C $repository rev-parse HEAD).Trim()

        $archivePath = Join-Path $runRoot 'source/payload.zip'
        $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        $payloadBytes = [byte[]](0x4D, 0x5A, 0x01, 0x02)
        try {
            $entry = $archive.CreateEntry('ExampleMod/payload.dll')
            $entryStream = $entry.Open()
            try { $entryStream.Write($payloadBytes, 0, $payloadBytes.Length) } finally { $entryStream.Dispose() }
        }
        finally { $archive.Dispose(); $archiveStream.Dispose() }
        $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $payloadSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes)).ToLowerInvariant()
        $statePath = Join-Path $runRoot 'state.json'
        $state = [ordered]@{
            schemaVersion = 15; workflowSchemaVersion = 15; runId = $runId; statePath = $statePath
            repositoryRoot = $repository; status = 'worktree-ready'; runRoot = $runRoot; artifactsRoot = $artifactsRoot
            worktreePath = $repository; mod = 'ExampleMod'; repoModDirectory = 'ExampleMod'; modRelativePath = $modRelativePath
            modLockPath = $lockPath; modLockKey = $lockKey; baseOid = $c0
            evidenceChain = [ordered]@{ c0Oid = $c0 }
            archive = [ordered]@{ path = $archivePath; filename = 'payload.zip'; size = (Get-Item -LiteralPath $archivePath).Length; sha256 = $archiveSha }
            securityOverrides = @(); completedStages = @(); stageTimings = [ordered]@{}
        }
        $null = Set-TestRunSkillSourcePin -State $state -SourcePinPath $script:skillSourcePinPath
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        [ordered]@{
            schemaVersion = 2; runId = $runId; canonicalModRelativePath = $modRelativePath; modLockKey = $lockKey
            plannedStatePath = $statePath; statePath = $statePath; reservationToken = [guid]::NewGuid().ToString('N')
            workerToken = $null; machineName = $null; workerId = $null; workerProcessStartTicks = $null
            leaseMode = 'reserved'; reservationState = 'between-stages'; heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $lockPath 'owner.json') -NoNewline

        (& $runnerPath verify-source -RepositoryRoot $repository -StatePath $statePath -PassThru).result | Should -Be 'passed'
        { & $runnerPath extract -RepositoryRoot $repository -StatePath $statePath -PassThru } |
            Should -Throw '*Security approval required for changed risky archive payload*'
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable).status | Should -Be 'waiting-user'

        $approvalPath = Join-Path $TestDrive 'payload-approval.json'
        [IO.File]::WriteAllText($approvalPath, ([ordered]@{
            schemaVersion = 1; runId = $runId; archiveSha256 = $archiveSha
            approvals = @([ordered]@{ relativePath = 'ExampleMod/payload.dll'; fileSha256 = $payloadSha })
        } | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        (& $runnerPath extract -RepositoryRoot $repository -StatePath $statePath -SecurityOverridePath $approvalPath -PassThru).result | Should -Be 'passed'
        $finalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-TestJson -AsHashtable
        (Get-FileHash -LiteralPath $finalState.securityOverrideReceipt.path -Algorithm SHA256).Hash.ToLowerInvariant() |
            Should -Be $finalState.securityOverrideReceipt.sha256
        $manifest = Get-Content -LiteralPath $finalState.extractionManifest.path -Raw | ConvertFrom-TestJson -AsHashtable
        $payload = @($manifest.files | Where-Object path -eq 'ExampleMod/payload.dll')[0]
        $payload.securityDisposition.result | Should -Be 'approved-exact-tuple'
        $payload.securityDisposition.archiveSha256 | Should -Be $archiveSha
        $payload.securityDisposition.fileSha256 | Should -Be $payloadSha
        (& $validatorPath -StatePath $statePath -SecurityPayloadOnly -PassThru).result | Should -Be 'passed'

        $approvalArtifact = Get-Content -LiteralPath $finalState.securityOverrideReceipt.path -Raw | ConvertFrom-TestJson -AsHashtable
        $approvalArtifact.approvals[0].fileSha256 = ('0' * 64)
        [IO.File]::WriteAllText($finalState.securityOverrideReceipt.path, ($approvalArtifact | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        { & $validatorPath -StatePath $statePath -SecurityPayloadOnly -PassThru } |
            Should -Throw '*Security override receipt SHA-256 changed*'
    }

    # Scenario: A valid-looking state keeps the canonical reservation path string, but that directory is replaced by a junction.
    # Purpose: Reject the physical reservation boundary before reading or writing owner.json outside the repository.
    It 'InterT225_RejectsAReparseModReservationBeforeReadingItsOwner' {
        $repository = Join-Path $TestDrive 'reservation-reparse-repository'
        $runId = '57575757-6666-4777-8888-999999999999'
        $modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        $lockKeyBytes = [Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant())
        $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($lockKeyBytes)).ToLowerInvariant()
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/examplemod-57575757'
        $artifactsRoot = Join-Path $runRoot 'artifacts'
        $lockParent = Join-Path $repository 'AI Auto Update/In Progress/.locks/mod'
        $lockPath = Join-Path $lockParent "$lockKey.lock"
        $outside = Join-Path $TestDrive 'reservation-reparse-outside'
        New-Item -ItemType Directory -Path $artifactsRoot, $lockParent, $outside -Force | Out-Null

        $archivePath = Join-Path $runRoot 'hostile.zip'
        $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $archive.CreateEntry('ExampleMod/../../escape.lua')
            $entryStream = $entry.Open()
            try { $entryStream.WriteByte(65) } finally { $entryStream.Dispose() }
        }
        finally { $archive.Dispose(); $archiveStream.Dispose() }

        $statePath = Join-Path $runRoot 'state.json'
        $state = [ordered]@{
            schemaVersion = 15; workflowSchemaVersion = 15; runId = $runId; statePath = $statePath
            repositoryRoot = $repository; status = 'worktree-ready'; runRoot = $runRoot; artifactsRoot = $artifactsRoot
            mod = 'ExampleMod'; repoModDirectory = 'ExampleMod'; modRelativePath = $modRelativePath
            modLockPath = $lockPath; modLockKey = $lockKey
            archive = [ordered]@{ path = $archivePath; sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() }
            completedStages = @(); stageTimings = [ordered]@{}
        }
        $null = Set-TestRunSkillSourcePin -State $state -SourcePinPath $script:skillSourcePinPath
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $owner = [ordered]@{
            schemaVersion = 2
            runId = $runId; canonicalModRelativePath = $modRelativePath; modLockKey = $lockKey
            plannedStatePath = $statePath; statePath = $statePath
            reservationToken = [guid]::NewGuid().ToString('N'); workerToken = $null
            machineName = $null; workerId = $null; workerProcessStartTicks = $null
            leaseMode = 'reserved'; reservationState = 'between-stages'; heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $ownerPath = Join-Path $outside 'owner.json'
        [IO.File]::WriteAllText($ownerPath, ($owner | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $ownerBefore = [IO.File]::ReadAllBytes($ownerPath)
        New-Item -ItemType Junction -Path $lockPath -Target $outside | Out-Null

        { & $runnerPath verify-source -RepositoryRoot $repository -StatePath $statePath -PassThru } |
            Should -Throw '*reparse*'
        [Convert]::ToHexString([IO.File]::ReadAllBytes($ownerPath)) | Should -Be ([Convert]::ToHexString($ownerBefore))
        Test-Path -LiteralPath (Join-Path $runRoot 'staging/extracted') | Should -Be $false
    }

    # Scenario: State retains the canonical lock key and owner while changing the MOD path protected by that reservation.
    # Purpose: Bind every resume to the exact canonical MOD path, fixed run root, and planned state path instead of trusting the lock key alone.
    It 'InterT226_RejectsAStateThatChangesTheCanonicalReservationTuple' {
        $repository = Join-Path $TestDrive 'reservation-tuple-repository'
        $runId = '58585858-6666-4777-8888-999999999999'
        $modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        $lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant()))).ToLowerInvariant()
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/examplemod-58585858'
        $artifactsRoot = Join-Path $runRoot 'artifacts'
        $lockPath = Join-Path $repository "AI Auto Update/In Progress/.locks/mod/$lockKey.lock"
        New-Item -ItemType Directory -Path $artifactsRoot, $lockPath -Force | Out-Null
        $archivePath = Join-Path $runRoot 'hostile.zip'
        $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $archive.CreateEntry('ExampleMod/../../escape.lua')
            $entryStream = $entry.Open()
            try { $entryStream.WriteByte(65) } finally { $entryStream.Dispose() }
        }
        finally { $archive.Dispose(); $archiveStream.Dispose() }

        $statePath = Join-Path $runRoot 'state.json'
        $state = [ordered]@{
            schemaVersion = 15; workflowSchemaVersion = 15; runId = $runId; statePath = $statePath
            repositoryRoot = $repository; status = 'worktree-ready'; runRoot = $runRoot; artifactsRoot = $artifactsRoot
            mod = 'ExampleMod'; repoModDirectory = 'ExampleMod'
            modRelativePath = 'Warhammer 40,000 DARKTIDE/mods/OtherMod'
            modLockPath = $lockPath; modLockKey = $lockKey
            archive = [ordered]@{ path = $archivePath; sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() }
            completedStages = @(); stageTimings = [ordered]@{}
        }
        $null = Set-TestRunSkillSourcePin -State $state -SourcePinPath $script:skillSourcePinPath
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        [ordered]@{
            schemaVersion = 2
            runId = $runId; canonicalModRelativePath = $modRelativePath; modLockKey = $lockKey
            plannedStatePath = $statePath; statePath = $statePath
            reservationToken = [guid]::NewGuid().ToString('N'); workerToken = $null
            machineName = $null; workerId = $null; workerProcessStartTicks = $null
            leaseMode = 'reserved'; reservationState = 'between-stages'; heartbeat = [DateTimeOffset]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $lockPath 'owner.json') -NoNewline

        { & $runnerPath verify-source -RepositoryRoot $repository -StatePath $statePath -PassThru } |
            Should -Throw '*canonical reservation tuple*'
        Test-Path -LiteralPath (Join-Path $runRoot 'staging/extracted') | Should -Be $false
    }
}
