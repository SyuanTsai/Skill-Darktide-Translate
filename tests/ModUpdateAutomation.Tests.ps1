Describe 'Deterministic Darktide MOD update automation' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $skillRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod'
        $runnerPath = Join-Path $skillRoot 'scripts/mod-update.ps1'
        $validatorPath = Join-Path $skillRoot 'scripts/Test-ModUpdateCandidate.ps1'
    }

    # Scenario: An agent selects the Skill for an archive-backed MOD update or recovery.
    # Purpose: Keep one fixed runner, an independent validator, and only the required progressive-disclosure reference discoverable.
    It 'UnitT100_PublishesTheRunnerValidatorAndAutomationReference' {
        Test-Path -LiteralPath $runnerPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath $validatorPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $skillRoot 'references/automation.md') -PathType Leaf | Should -Be $true

        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
        $skill | Should -Match 'scripts/mod-update\.ps1'
        $skill | Should -Match 'scripts/Test-ModUpdateCandidate\.ps1'
        $skill | Should -Match 'references/automation\.md'
    }

    # Scenario: A caller invokes a single stage or resumes the same run.
    # Purpose: Preserve the fixed command surface, structured JSON, timing, state, and idempotency contracts.
    It 'UnitT110_DeclaresTheFixedResumableStageContract' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($stage in @('claim', 'verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot', 'run')) {
            $runner | Should -Match ([regex]::Escape("'$stage'"))
        }

        $runner | Should -Match 'state\.json'
        $runner | Should -Match 'stageTimings'
        $runner | Should -Match 'activeMilliseconds'
        $runner | Should -Match 'waitingMilliseconds'
        $runner | Should -Match 'artifactSha256'
        $runner | Should -Match 'ConvertTo-Json'
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
        $validator | Should -Not -Match 'Test-ManifestAgainstDirectory'
        $validator | Should -Match 'sha256'
        $validator | Should -Match 'exit 1'
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
        $runner | Should -Not -Match 'Start-Sleep|--watch|while\s*\('
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

    # Scenario: A real ZIP changes an active localization file while preserving CRLF-sensitive whitespace and adds a non-target file.
    # Purpose: Execute claim through the independent Gate and prove C0/C1/C2/C3/F, approved byte spans, manifests, timings, and rerun idempotency.
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

        $claim = & $runnerPath claim -RepositoryRoot $fixtureRepo -ArchivePath $archivePath -ModDirectory 'ExampleMod' -BaseRef HEAD -PassThru
        $claim.result | Should -Be 'passed'
        $statePath = $claim.statePath

        $claimedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $secondArchivePath = Join-Path $queueRoot 'ExampleMod-second.zip'
        [IO.File]::Copy($claimedState.archive.path, $secondArchivePath)
        { & $runnerPath claim -RepositoryRoot $fixtureRepo -ArchivePath $secondArchivePath -ModDirectory 'ExampleMod' -BaseRef HEAD -PassThru } |
            Should -Throw '*already owns this canonical MOD identity*'
        Test-Path -LiteralPath $secondArchivePath -PathType Leaf | Should -Be $true
        [IO.File]::Delete($secondArchivePath)

        $incompleteClaim = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $incompleteClaim.status = 'claiming'
        $incompleteClaim.completedStages = @($incompleteClaim.completedStages | Where-Object { $_ -ne 'claim' })
        $incompleteClaim.stageTimings.Remove('claim')
        [IO.File]::WriteAllText($statePath, ($incompleteClaim | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        $claimRecovery = & $runnerPath claim -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $claimRecovery.result | Should -Be 'passed'
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).lastRecovery.reason | Should -Be 'incomplete claim reattached to original run tuple'

        $writerState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
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
        $preExtractState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $partialExtraction = Join-Path $preExtractState.runRoot 'staging/extracted'
        New-Item -ItemType Directory -Path $partialExtraction -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $partialExtraction 'partial.txt'), 'crash residue', [Text.UTF8Encoding]::new($false))
        (& $runnerPath extract -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).result | Should -Be 'passed'
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
        (& $runnerPath localization -RepositoryRoot $fixtureRepo -StatePath $statePath -LocalizationPlanPath $planPath -PassThru).result | Should -Be 'passed'
        (& $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).result | Should -Be 'passed'
        $validation = & $runnerPath validate -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $validation.result | Should -Be 'passed'

        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.candidateGate.status | Should -Be 'passed'
        foreach ($field in @('c0Oid', 'c1Oid', 'c2Oid', 'c3Oid', 'fOid', 'c0TreeOid', 'c1TreeOid', 'c2TreeOid', 'c3TreeOid', 'fTreeOid')) {
            $state.evidenceChain[$field] | Should -Match '^[0-9a-f]{40}$'
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
            $state.stageTimings[$stageName].waitingMilliseconds | Should -Be 0
            $state.stageTimings[$stageName].artifactSha256 | Should -Match '^[0-9a-f]{64}$'
        }
        $headBeforeRerun = (& git -C $state.worktreePath rev-parse HEAD).Trim()
        (& $runnerPath claim -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).idempotent | Should -Be $true
        (& $runnerPath install -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru).idempotent | Should -Be $true
        $rerun = & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru
        $rerun.idempotent | Should -Be $true
        (& git -C $state.worktreePath rev-parse HEAD).Trim() | Should -Be $headBeforeRerun

        $receiptBytes = [IO.File]::ReadAllBytes($state.evidenceReceipt.path)
        Remove-Item -LiteralPath $state.evidenceReceipt.path
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*missing its recorded artifact*'
        [IO.File]::WriteAllBytes($state.evidenceReceipt.path, $receiptBytes)

        $recoveryState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $recoveryState.status = 'candidate-committed'
        $recoveryState.published = $true
        $recoveryState.completedStages = @($recoveryState.completedStages | Where-Object { $_ -ne 'build-commits' })
        [IO.File]::WriteAllText($statePath, ($recoveryState | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
        { & $runnerPath build-commits -RepositoryRoot $fixtureRepo -StatePath $statePath -PassThru } |
            Should -Throw '*append-only*'

        $tamperState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
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
        $runRoot = Join-Path $TestDrive 'hostile-run'
        $artifactsRoot = Join-Path $runRoot 'artifacts'
        $lockPath = Join-Path $runRoot 'lock'
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
        $runId = [guid]::NewGuid().ToString()
        $lockKey = 'a' * 64
        $state = [ordered]@{
            runId = $runId
            statePath = $statePath
            status = 'worktree-ready'
            runRoot = $runRoot
            artifactsRoot = $artifactsRoot
            modLockPath = $lockPath
            modLockKey = $lockKey
            repoModDirectory = 'ExampleMod'
            archive = [ordered]@{
                path = $archivePath
                sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            completedStages = @()
            stageTimings = [ordered]@{}
        }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $owner = [ordered]@{ runId = $runId; modLockKey = $lockKey; statePath = $statePath }
        [IO.File]::WriteAllText((Join-Path $lockPath 'owner.json'), ($owner | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

        { & $runnerPath verify-source -RepositoryRoot $TestDrive -StatePath $statePath -PassThru } |
            Should -Throw '*path traversal*'
        (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).status | Should -Be 'waiting-user'
        Test-Path -LiteralPath (Join-Path $runRoot 'staging/extracted') | Should -Be $false
    }

    # Scenario: A ZIP has the wrong canonical root or declares a Unix symlink entry.
    # Purpose: Execute both identity and link-type security blocks before any filesystem extraction.
    It 'InterT220_RejectsInvalidRootAndSymlinkArchives' {
        foreach ($case in @('invalid-root', 'symlink')) {
            $runRoot = Join-Path $TestDrive $case
            $artifactsRoot = Join-Path $runRoot 'artifacts'
            $lockPath = Join-Path $runRoot 'lock'
            New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
            New-Item -ItemType Directory -Path $lockPath -Force | Out-Null
            $archivePath = Join-Path $runRoot "$case.zip"
            $archiveStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew)
            $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $entryName = if ($case -eq 'invalid-root') { 'OtherMod/file.lua' } else { 'ExampleMod/link.lua' }
                $entry = $archive.CreateEntry($entryName)
                if ($case -eq 'symlink') { $entry.ExternalAttributes = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]2684354560), 0) }
                $entryStream = $entry.Open()
                try { $entryStream.WriteByte(65) } finally { $entryStream.Dispose() }
            }
            finally { $archive.Dispose(); $archiveStream.Dispose() }

            $statePath = Join-Path $runRoot 'state.json'
            $runId = [guid]::NewGuid().ToString()
            $lockKey = 'b' * 64
            $state = [ordered]@{
                runId = $runId; statePath = $statePath; status = 'worktree-ready'; runRoot = $runRoot
                artifactsRoot = $artifactsRoot; modLockPath = $lockPath; modLockKey = $lockKey; repoModDirectory = 'ExampleMod'
                archive = [ordered]@{ path = $archivePath; sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() }
                completedStages = @(); stageTimings = [ordered]@{}
            }
            [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $lockPath 'owner.json'), ([ordered]@{ runId = $runId; modLockKey = $lockKey; statePath = $statePath } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $expected = if ($case -eq 'invalid-root') { '*Invalid archive root*' } else { '*symlink rejected*' }
            { & $runnerPath verify-source -RepositoryRoot $TestDrive -StatePath $statePath -PassThru } | Should -Throw $expected
            Test-Path -LiteralPath (Join-Path $runRoot 'staging/extracted') | Should -Be $false
        }
    }
}
