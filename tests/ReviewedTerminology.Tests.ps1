# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Schema 15 reviewed terminology' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $scriptRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/auto-update-darktide-mod/scripts'
        $applyScript = Join-Path $scriptRoot 'Apply-LocalizationWorkset.ps1'
        $receiptScript = Join-Path $scriptRoot 'Test-LocalizationWorksetReceipt.ps1'

        function New-ReviewedTerminologyFixture {
            param([string] $OldSource = 'Trauma Staff Effect?', [string] $NewSource = $OldSource,
                [string] $PriorText = '震盪杖特效？', [string] $Translation = '虛空爆破力場法杖特效？',
                [string] $Extra = '', [switch] $NoDrift, [string] $GeneratedSourceId)

            $expectedNexusId = 592
            $sourceId = "nexus-$expectedNexusId"
            if (-not $GeneratedSourceId) { $GeneratedSourceId = $sourceId }

            $repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $mod = 'mods/ExampleMod'
            $file = 'example_localization.lua'
            $relative = "$mod/$file"
            $run = Join-Path $repository 'run'
            $stage = Join-Path $run 'staging/localization-workset-input/ExampleMod'
            $review = Join-Path $run 'review-artifacts'
            $relativeSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($relative))).ToLowerInvariant()
            $artifacts = Join-Path $run ('artifacts/localization/' + $relativeSha.Substring(0, 16))
            $null = New-Item -ItemType Directory -Path @((Join-Path $repository $mod), $stage, $review, $artifacts) -Force
            & git -C $repository init --quiet
            if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize synthetic Git fixture.' }
            $oldText = @"
return {
    staff_circle_enabled = { en = "$OldSource", ["zh-tw"] = "$PriorText", fr = "Effet" },
    unselected = { en = "Same", ["zh-tw"] = "$PriorText" },
    drift = { en = "Stable", ["zh-tw"] = "留存" },
$Extra}
"@
            $newText = $oldText.Replace('en = "' + $OldSource + '"', 'en = "' + $NewSource + '"')
            if (-not $NoDrift) { $newText = $newText.Replace('"留存"', '"上游"') }
            $oldFile = Join-Path $repository $relative
            [IO.File]::WriteAllText($oldFile, ($oldText -replace '\r?\n', "`n"))
            & git -C $repository -c core.autocrlf=false add -- $relative
            if ($LASTEXITCODE -ne 0) { throw 'Cannot stage synthetic OLD fixture.' }
            Add-TestTranslationRules -RepositoryRoot $repository
            $tree = (& git -C $repository write-tree).Trim()
            if ($LASTEXITCODE -ne 0) { throw 'Cannot write synthetic base tree.' }
            $base = (& git -C $repository -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree $tree -m 'Synthetic OLD').Trim()
            if ($LASTEXITCODE -ne 0) { throw 'Cannot create synthetic immutable base.' }
            $rawNew = Join-Path $artifacts 'new.lua'
            $stageFile = Join-Path $stage $file
            $newText = $newText -replace '\r?\n', "`r`n"
            [IO.File]::WriteAllText($rawNew, $newText, [Text.UTF8Encoding]::new($true))
            [IO.File]::Copy($rawNew, $stageFile)
            $worksetPath = Join-Path $review 'localization-workset.json'
            & (Join-Path $scriptRoot 'New-LocalizationWorkset.ps1') -RepositoryRoot $repository -BaseOid $base `
                -ModRelativePath $mod -StagingModPath $stage -OutputPath $worksetPath -SourceId $GeneratedSourceId -PassThru |
                Out-Null
            $workset = Get-Content -LiteralPath $worksetPath -Raw | ConvertFrom-Json -AsHashtable
            $unit = @($workset.units | Where-Object key -CEQ 'staff_circle_enabled')[0]
            $request = [ordered]@{
                schemaVersion = 1
                nexusId = $expectedNexusId
                fileId = 1201
                oldSha256 = $workset.old.sha256
                newSha256 = $workset.new.sha256
                immutableContractSha256 = $workset.immutableContractSha256
                rulesSha256 = $workset.translationBinding.rulesSha256
                glossarySha256 = $workset.translationBinding.glossarySha256
                reviewer = 'example-reviewer'
                reviewReference = 'https://github.com/example/mods/pull/42#pullrequestreview-123'
                units = @()
                terminologyCorrection = [ordered]@{
                    sourceId = $sourceId; containerPath = '$'; key = 'staff_circle_enabled'
                    occurrence = 1; unitId = $unit.unitId; action = 'NONE'
                    old = [ordered]@{ sourceRaw = '"' + $OldSource + '"'; zhTwRaw = '"' + $PriorText + '"' }
                    new = [ordered]@{ sourceRaw = '"' + $NewSource + '"'; zhTwRaw = '"' + $PriorText + '"' }
                    translation = $Translation
                }
            }
            $requestPath = Join-Path $review 'reviewed-request.json'
            $request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $requestPath -NoNewline
            @{
                Request = $request
                Workset = $workset
                StageFile = $stageFile
                MergedPath = Join-Path $artifacts 'merged.lua'
                RunRoot = $run
                Parameters = @{
                    WorksetPath = $worksetPath; NewPath = $rawNew; RepositoryRoot = $repository
                    ExpectedBaseOid = $base; ExpectedModRelativePath = $mod; TerminologyRequestPath = $requestPath
                    ExpectedNexusId = $expectedNexusId; ExpectedMainFileId = 1201; PassThru = $true
                }
                NewText = $newText
            }
        }
    }

    # Scenario: InterT01 verifies one explicit unchanged terminology correction from raw OLD and NEW.
    # Purpose: Exercise generation, production Apply and independent Receipt with real Git and exact Lua bytes.
    It 'InterT01_VerifiesReviewedTerminologyAndPreservesUnselectedBytes' {
        # Given
        $fixture = New-ReviewedTerminologyFixture
        $parameters = $fixture.Parameters
        $encoding = [Text.UTF8Encoding]::new($true)
        $priorWorkset = $fixture.Workset
        $workingOld = Join-Path $parameters.RepositoryRoot $priorWorkset.old.path
        [IO.File]::WriteAllText($workingOld, 'A working-tree file that differs from the pinned blob')
        $expectedText = $fixture.NewText.Replace('["zh-tw"] = "震盪杖特效？", fr', '["zh-tw"] = "虛空爆破力場法杖特效？", fr').Replace('"上游"', '"留存"')

        # When
        $applied = & $applyScript @parameters
        [IO.File]::Copy($fixture.StageFile, $fixture.MergedPath)
        $verified = & $receiptScript @parameters -RunRoot $fixture.RunRoot -MergedPath $fixture.MergedPath

        # Then
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.StageFile)) |
            Should -BeExactly ([Convert]::ToBase64String([byte[]]($encoding.GetPreamble() + $encoding.GetBytes($expectedText))))
        $applied.result | Should -BeExactly 'passed'
        $verified.result | Should -BeExactly 'passed'
        $verified.editCount | Should -Be 2
        $proof = $verified.terminologyCorrection
        $proof.schemaVersion | Should -Be 1
        $proof.requestSha256 | Should -BeExactly ((Get-FileHash -LiteralPath $parameters.TerminologyRequestPath).Hash.ToLowerInvariant())
        $proof.nexusId | Should -Be 592
        $proof.fileId | Should -Be 1201
        $proof.sourceId | Should -BeExactly 'nexus-592'
        $proof.action | Should -BeExactly 'NONE'
        $proof.edit.operation | Should -BeExactly 'TERMINOLOGY_REPLACE'
        $proof.edit.oldSha256 | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoding.GetBytes('"震盪杖特效？"'))).ToLowerInvariant())
        $proof.edit.replacementBase64 | Should -BeExactly ([Convert]::ToBase64String($encoding.GetBytes('"虛空爆破力場法杖特效？"')))
        $proof.reviewer | Should -BeExactly $fixture.Request.reviewer
        $proof.reviewReference | Should -BeExactly $fixture.Request.reviewReference
        ($applied.terminologyCorrection | ConvertTo-Json -Depth 10 -Compress) |
            Should -BeExactly ($proof | ConvertTo-Json -Depth 10 -Compress)
        $workset = Get-Content -LiteralPath $parameters.WorksetPath -Raw | ConvertFrom-Json -AsHashtable
        $workset.immutableContractSha256 | Should -BeExactly $priorWorkset.immutableContractSha256
        (ConvertTo-Json -InputObject $workset.units -Depth 20 -Compress) |
            Should -BeExactly (ConvertTo-Json -InputObject $priorWorkset.units -Depth 20 -Compress)
    }

    # Scenario: InterT02 applies the workset using only the ordinary entry points.
    # Purpose: Keep both NONE fields byte-exact and retain the ordinary evidence schema.
    It 'InterT02_PreservesOrdinaryNoneWithoutTerminologyOptions' {
        # Given
        $fixture = New-ReviewedTerminologyFixture -GeneratedSourceId 'examplemod'
        $parameters = $fixture.Parameters
        $encoding = [Text.UTF8Encoding]::new($true)
        $null = $parameters.Remove('TerminologyRequestPath')
        $null = $parameters.Remove('ExpectedNexusId')
        $null = $parameters.Remove('ExpectedMainFileId')

        # When
        $applied = & $applyScript -WorksetPath $parameters.WorksetPath -PassThru
        [IO.File]::Copy($fixture.StageFile, $fixture.MergedPath)
        $verified = & $receiptScript @parameters -RunRoot $fixture.RunRoot -MergedPath $fixture.MergedPath

        # Then
        $expectedText = $fixture.NewText.Replace('"上游"', '"留存"')
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.StageFile)) |
            Should -BeExactly ([Convert]::ToBase64String([byte[]]($encoding.GetPreamble() + $encoding.GetBytes($expectedText))))
        $applied.editCount | Should -Be 1
        $verified.editCount | Should -Be 1
        $applied.Contains('terminologyCorrection') | Should -BeFalse
        $verified.Contains('terminologyCorrection') | Should -BeFalse
    }

    # Scenario: InterT03 receives a request with stale approvals, mismatched identity, or an invalid proof shape.
    # Purpose: Reject unproven inputs before any staging or workset write.
    foreach ($case in @(
        @{ label = 'Nexus ID'; alter = { $request.nexusId++ }; expectedMessage = '*Nexus, MAIN file, or generated source ID*' }
        @{ label = 'MAIN file ID'; alter = { $request.fileId++ }; expectedMessage = '*Nexus, MAIN file, or generated source ID*' }
        @{ label = 'missing trusted MAIN file ID'; alter = { $parameters.Remove('ExpectedMainFileId') }; expectedMessage = '*trusted Nexus and MAIN file IDs*' }
        @{ label = 'request source ID'; alter = { $request.terminologyCorrection.sourceId = 'nexus-593' }; expectedMessage = '*generated source ID*' }
        @{ label = 'generated source ID'; generatedSourceId = 'nexus-593'; alter = {}; expectedMessage = '*generated source ID*' }
        @{ label = 'lookalike source ID'; alter = { $request.terminologyCorrection.sourceId += [char]0x200F }; expectedMessage = '*generated source ID*' }
        @{ label = 'unit ID'; alter = { $request.terminologyCorrection.unitId += 'x' }; expectedMessage = '*locator*' }
        @{ label = 'key'; alter = { $request.terminologyCorrection.key = 'unselected' }; expectedMessage = '*locator*' }
        @{ label = 'container'; alter = { $request.terminologyCorrection.containerPath = '$.moved' }; expectedMessage = '*locator*' }
        @{ label = 'occurrence'; alter = { $request.terminologyCorrection.occurrence++ }; expectedMessage = '*locator*' }
        @{ label = 'request action'; alter = { $request.terminologyCorrection.action = 'AI_REQUIRED' }; expectedMessage = '*unchanged NONE*' }
        @{ label = 'OLD source literal'; alter = { $request.terminologyCorrection.old.sourceRaw = '"Wrong OLD"' }; expectedMessage = '*prior literals*' }
        @{ label = 'NEW zh-tw literal'; alter = { $request.terminologyCorrection.new.zhTwRaw = '"錯誤"' }; expectedMessage = '*prior literals*' }
        @{ label = 'OLD digest'; alter = { $request.oldSha256 = 'a' * 64 }; expectedMessage = '*stale*' }
        @{ label = 'NEW digest'; alter = { $request.newSha256 = 'b' * 64 }; expectedMessage = '*stale*' }
        @{ label = 'immutable digest'; alter = { $request.immutableContractSha256 = 'c' * 64 }; expectedMessage = '*stale*' }
        @{ label = 'rules digest'; alter = { $request.rulesSha256 = 'd' * 64 }; expectedMessage = '*stale*' }
        @{ label = 'glossary digest'; alter = { $request.glossarySha256 = 'e' * 64 }; expectedMessage = '*stale*' }
        @{ label = 'base OID'; alter = { $parameters.ExpectedBaseOid = 'a' * 40 }; expectedMessage = '*pinned base OID*' }
        @{ label = 'string ID'; alter = { $request.fileId = '1201' }; expectedMessage = '*positive JSON integers*' }
        @{ label = 'nonempty units'; alter = { $request.units = @('another unit') }; expectedMessage = '*empty JSON array*' }
        @{ label = 'extra proof field'; alter = { $request.terminologyCorrection.new.extra = 'extra' }; expectedMessage = '*duplicate or unexpected field*' }
        @{ label = 'missing proof field'; alter = { $request.terminologyCorrection.old.Remove('zhTwRaw') }; expectedMessage = '*missing a required field*' }
        @{ label = 'malformed reviewer'; alter = { $request.reviewer = 'example reviewer' }; expectedMessage = '*malformed review attestation*' }
        @{ label = 'no-op'; alter = { $request.terminologyCorrection.translation = '震盪杖特效？' }; expectedMessage = '*no-op*' }
    )) {
        It "InterT03_RejectsInvalidReviewedRequest: $($case.label)" -ForEach @($case) {
            param($alter, $expectedMessage, $generatedSourceId)

            # Given
            $fixture = New-ReviewedTerminologyFixture -GeneratedSourceId $generatedSourceId
            $request = $fixture.Request
            $parameters = $fixture.Parameters
            $worksetHash = (Get-FileHash -LiteralPath $parameters.WorksetPath).Hash
            $stageHash = (Get-FileHash -LiteralPath $fixture.StageFile).Hash
            . $alter
            $request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameters.TerminologyRequestPath -NoNewline

            # When / Then
            { & $applyScript @parameters } | Should -Throw $expectedMessage
            (Get-FileHash -LiteralPath $parameters.WorksetPath).Hash | Should -BeExactly $worksetHash
            (Get-FileHash -LiteralPath $fixture.StageFile).Hash | Should -BeExactly $stageHash
        }
    }

    # Scenario: InterT04 receives duplicate keys, non-JSON syntax, or an oversized request.
    # Purpose: Check the raw JSON proof before PowerShell can collapse a duplicate property.
    It 'InterT04_RejectsInvalidProofBytes: <label>' -ForEach @(
        @{ label = 'top-level duplicate'; alter = { $json -replace '"nexusId":592', '"nexusId":592,"nexusId":592' }; expectedMessage = '*duplicate or unexpected field*' }
        @{ label = 'nested escaped duplicate'; alter = { $json -replace '"sourceRaw":', '"\u0073ourceRaw":"bad","sourceRaw":' }; expectedMessage = '*duplicate or unexpected field*' }
        @{ label = 'invalid syntax'; alter = { $json + '}' }; expectedMessage = '*Json*' }
        @{ label = 'oversized'; alter = { $json + (' ' * 65536) }; expectedMessage = '*65536 bytes*' }
    ) {
        # Given
        $fixture = New-ReviewedTerminologyFixture
        $parameters = $fixture.Parameters
        $json = $fixture.Request | ConvertTo-Json -Depth 10 -Compress
        [IO.File]::WriteAllText($parameters.TerminologyRequestPath, (& $alter))

        # When / Then
        { & $applyScript @parameters } | Should -Throw $expectedMessage
    }

    # Scenario: InterT05 targets parsed bytes that cannot prove one unchanged literal.
    # Purpose: Prevent a changed action, duplicate or dynamic locator, or expression from becoming a terminology edit.
    It 'InterT05_RejectsUnprovenParsedUnit: <label>' -ForEach @(
        @{ label = 'changed English'; fixtureArgs = @{ NewSource = 'Changed effect?' }; expectedMessage = '*unchanged NONE*' }
        @{ label = 'changed English format control'; fixtureArgs = @{ NewSource = ('Trauma Staff Effect?' + [char]0x200F) }; expectedMessage = '*unchanged NONE*' }
        @{ label = 'concatenated source'; fixtureArgs = @{ OldSource = 'Trauma" .. " Staff Effect?' }; expectedMessage = '*quoted Lua literal*' }
        @{ label = 'concatenated translation'; fixtureArgs = @{ PriorText = '震盪杖" .. "特效？' }; expectedMessage = '*quoted Lua literal*' }
        @{ label = 'non-UTF-8 escape'; fixtureArgs = @{ PriorText = '震盪杖\xFF特效？' }; expectedMessage = '*decodes as UTF-8*' }
        @{ label = 'duplicate unit'; fixtureArgs = @{ Extra = 'staff_circle_enabled = { en = "Trauma Staff Effect?", ["zh-tw"] = "震盪杖特效？" },' }; expectedMessage = '*ambiguous*' }
        @{ label = 'duplicate scalar key'; fixtureArgs = @{ Extra = '["staff_circle_enabled"] = false,' }; expectedMessage = '*ambiguous*' }
        @{ label = 'computed key'; fixtureArgs = @{ Extra = '[unknownKey] = false,' }; expectedMessage = '*ambiguous computed Lua key*' }
    ) {
        # Given
        $fixture = New-ReviewedTerminologyFixture @fixtureArgs
        $parameters = $fixture.Parameters

        # When / Then
        { & $applyScript @parameters } | Should -Throw $expectedMessage
    }

    # Scenario: InterT06 presents an explicit translation that changes existing protected structure.
    # Purpose: Retain named and printf argument order, Darktide markup, glyphs, format controls, and line shape.
    It 'InterT06_RejectsChangedProtectedContent: <label>' -ForEach @(
        @{ label = 'named argument order'; from = '{name} {count}'; to = '{count} {name}' }
        @{ label = 'printf argument order'; from = '%s %02d'; to = '%02d %s' }
        @{ label = 'markup'; from = '{#color(255,0,0)}'; to = '{#color(0,0,0)}' }
        @{ label = 'BMP PUA'; from = [string][char]0xE001; to = [string][char]0xE002 }
        @{ label = 'supplementary PUA'; from = [char]::ConvertFromUtf32(0xF0001); to = [char]::ConvertFromUtf32(0xF0002) }
        @{ label = 'format control'; from = [string][char]0x200F; to = '' }
        @{ label = 'supplementary format control'; from = [char]::ConvertFromUtf32(0xE0001); to = '' }
        @{ label = 'newline'; from = "`n"; to = ' ' }
        @{ label = 'blank line'; from = "`n`n第二列`n第三列"; to = "`n第二列`n`n第三列" }
    ) {
        # Given
        $prior = '{#color(255,0,0)}舊 {name} {count} %s %02d ' + [char]0xE001 + [char]::ConvertFromUtf32(0xF0001) +
            [char]0x200F + [char]::ConvertFromUtf32(0xE0001) + '\n\n第二列\n第三列{#reset()}'
        $approved = $prior.Replace('舊', '新').Replace('\n', "`n").Replace($from, $to)
        $fixture = New-ReviewedTerminologyFixture -PriorText $prior -Translation $approved
        $parameters = $fixture.Parameters

        # When / Then
        { & $applyScript @parameters } | Should -Throw '*protected*'
    }

    # Scenario: InterT07 applies reviewed plain text with intact placeholders, controls, glyphs, and newlines.
    # Purpose: Verify that safe literal encoding supports valid protected content and quotes without changing the file layout.
    It 'InterT07_PreservesProtectedTokensAndEscapesApprovedText' {
        # Given
        $prior = '{#color(255,0,0)}舊 {name} %s %02d ' + [char]0xE001 + '\n次列{#reset()}'
        $literal = $prior.Replace('舊', '新\"術語\"')
        $approved = $literal.Replace('\n', "`n").Replace('\"', '"')
        $fixture = New-ReviewedTerminologyFixture -PriorText $prior -Translation $approved -NoDrift
        $parameters = $fixture.Parameters

        # When
        $null = & $applyScript @parameters
        [IO.File]::Copy($fixture.StageFile, $fixture.MergedPath)
        $verified = & $receiptScript @parameters -RunRoot $fixture.RunRoot -MergedPath $fixture.MergedPath

        # Then
        $verified.editCount | Should -Be 1
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($verified.terminologyCorrection.edit.replacementBase64)) |
            Should -BeExactly ('"' + $literal + '"')
    }

    # Scenario: InterT08 reopens a completed run with a modified request or a modified artifact.
    # Purpose: Require Receipt to verify the actual proof, edit, and source/output bytes independently.
    It 'InterT08_ReconstructsProofAndRejectsTampering: <label>' -ForEach @(
        @{ label = 'request attestation'; alter = { $request.reviewer = 'other-reviewer' }; expectedMessage = '*independently reconstructed request and edit*' }
        @{ label = 'persisted evidence'; alter = { $workset.apply.terminologyCorrection.reviewReference = 'review-99' }; expectedMessage = '*independently reconstructed request and edit*' }
        @{ label = 'recorded edit'; alter = { $workset.apply.edits[-1].oldSha256 = 'a' * 64 }; expectedMessage = '*deterministic edit plan*' }
        @{ label = 'raw NEW file'; alter = { [IO.File]::AppendAllText($parameters.NewPath, '-- tampered') }; expectedMessage = '*Raw NEW localization evidence differs*' }
        @{ label = 'relocated raw NEW file'; alter = {
            $other = Join-Path $fixture.RunRoot 'review-artifacts/new.lua'
            [IO.File]::Copy($parameters.NewPath, $other)
            $parameters.NewPath = $other
        }; expectedMessage = '*fixed raw NEW localization evidence path*' }
        @{ label = 'merged evidence'; alter = { [IO.File]::AppendAllText($fixture.MergedPath, '-- tampered') }; expectedMessage = '*Merged localization evidence differs*' }
        @{ label = 'staged output'; alter = { [IO.File]::AppendAllText($fixture.StageFile, '-- tampered') }; expectedMessage = '*staged output differs*' }
        @{ label = 'missing terminology options'; alter = {
            $null = $parameters.Remove('TerminologyRequestPath')
            $null = $parameters.Remove('ExpectedNexusId')
            $null = $parameters.Remove('ExpectedMainFileId')
        }; expectedMessage = '*receipt fields are malformed*' }
    ) {
        # Given
        $fixture = New-ReviewedTerminologyFixture
        $parameters = $fixture.Parameters
        $null = & $applyScript @parameters
        [IO.File]::Copy($fixture.StageFile, $fixture.MergedPath)
        $workset = Get-Content -LiteralPath $parameters.WorksetPath -Raw | ConvertFrom-Json -AsHashtable
        $request = $fixture.Request
        $requestPath = $parameters.TerminologyRequestPath
        . $alter
        $request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $requestPath -NoNewline
        $workset | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $parameters.WorksetPath -NoNewline

        # When / Then
        { & $receiptScript @parameters -RunRoot $fixture.RunRoot -MergedPath $fixture.MergedPath } | Should -Throw $expectedMessage
    }

    # Scenario: InterT09 resumes a pending receipt on either side of the staged file write.
    # Purpose: Recover only with the original review and reject a missing, stale, or substituted request.
    It 'InterT09_RecoversOnlyWithTheSameRequest: <label>' -ForEach @(
        @{ label = 'before target write'; alreadyWritten = $false }
        @{ label = 'after target write'; alreadyWritten = $true }
    ) {
        # Given
        $fixture = New-ReviewedTerminologyFixture
        $parameters = $fixture.Parameters
        $requestBytes = [IO.File]::ReadAllBytes($parameters.TerminologyRequestPath)
        $first = & $applyScript @parameters
        $outputHash = (Get-FileHash -LiteralPath $fixture.StageFile).Hash
        $pending = Get-Content -LiteralPath $parameters.WorksetPath -Raw | ConvertFrom-Json -AsHashtable
        $pending.status = 'applying'
        $pending.apply.status = 'pending'
        $pending | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $parameters.WorksetPath -NoNewline
        if (-not $alreadyWritten) { [IO.File]::Copy($parameters.NewPath, $fixture.StageFile, $true) }
        $pendingHash = (Get-FileHash -LiteralPath $parameters.WorksetPath).Hash
        $stageHash = (Get-FileHash -LiteralPath $fixture.StageFile).Hash

        # When / Then
        { & $applyScript -WorksetPath $parameters.WorksetPath -PassThru } | Should -Throw '*same reviewed terminology request*'
        $originalDigest = $fixture.Request.newSha256
        $fixture.Request.newSha256 = 'a' * 64
        $fixture.Request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameters.TerminologyRequestPath -NoNewline
        { & $applyScript @parameters } | Should -Throw '*stale*'
        $fixture.Request.newSha256 = $originalDigest
        $fixture.Request.reviewReference = 'another-review'
        $fixture.Request | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $parameters.TerminologyRequestPath -NoNewline
        { & $applyScript @parameters } | Should -Throw '*recorded receipt*'
        (Get-FileHash -LiteralPath $parameters.WorksetPath).Hash | Should -BeExactly $pendingHash
        (Get-FileHash -LiteralPath $fixture.StageFile).Hash | Should -BeExactly $stageHash
        [IO.File]::WriteAllBytes($parameters.TerminologyRequestPath, $requestBytes)
        $recovered = & $applyScript @parameters
        $recovered.idempotent | Should -Be $alreadyWritten
        $recovered.terminologyCorrection.requestSha256 | Should -BeExactly $first.terminologyCorrection.requestSha256
        (Get-FileHash -LiteralPath $fixture.StageFile).Hash | Should -BeExactly $outputHash
        $repeated = & $applyScript @parameters
        $repeated.idempotent | Should -BeTrue
        $repeated.worksetSha256 | Should -BeExactly $recovered.worksetSha256
    }
}
