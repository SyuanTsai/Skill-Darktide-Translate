Describe 'Schema 15 source acquisition contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod/scripts'
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:skillSourcePinPath = New-TestSkillSourcePin -SkillRoot (Split-Path -Parent $scriptRoot) -OutputPath (Join-Path $TestDrive 'skill-source-pin.json')
    }

    # Scenario: A Schema 15 run needs a deterministic download boundary before the existing claim stage.
    # Purpose: Require separate acquisition and independent receipt verification entrypoints instead of extending claim with network behavior.
    It 'UnitT10_PublishesAcquisitionAndReceiptVerificationEntrypoints' {
        Test-Path -LiteralPath (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $scriptRoot 'Invoke-ModUpdateQueue.ps1') -PathType Leaf | Should -Be $true
    }

    # Scenario: Nexus metadata identifies the requested Main file as a RAR before any provider is invoked.
    # Purpose: Prevent unsupported archives from being downloaded or claimed while preserving a structured user-facing reason.
    It 'UnitT20_RejectsKnownUnsupportedArchivesBeforeDownload' {
        $runRoot = Join-Path $TestDrive 'known-rar'
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1
            gameDomain = 'warhammer40kdarktide'
            modId = 123
            mainFileId = 456
            version = '2.0.0'
            fileName = 'ExampleMod-2.0.0.rar'
            pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $incoming = Join-Path $runRoot '.incoming-test-run'
        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath `
            -IncomingDirectory $incoming `
            -DeliveryDirectory (Join-Path $runRoot 'source') `
            -Provider browser `
            -ReceiptPath (Join-Path $runRoot 'source-receipt.json') `
            -PassThru

        $result.status | Should -Be 'waiting-user'
        $result.waitingReason.code | Should -Be 'unsupported_archive_format'
        Test-Path -LiteralPath $incoming | Should -Be $false
    }

    # Scenario: A known-unsupported request is reached through a junction under the declared run root.
    # Purpose: Reject physical path indirection before even the early archive-extension return reads untrusted request bytes.
    It 'UnitT22_RejectsAReparseRequestBeforeTheUnsupportedArchiveFastPath' {
        $runRoot = Join-Path $TestDrive 'reparse-request-run'
        $outside = Join-Path $TestDrive 'reparse-request-outside'
        New-Item -ItemType Directory -Path $runRoot, $outside -Force | Out-Null
        $requestPath = Join-Path $outside 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.rar'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $linkedArtifacts = Join-Path $runRoot 'review-artifacts'
        New-Item -ItemType Junction -Path $linkedArtifacts -Target $outside | Out-Null

        { & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
                -SourceRequestPath (Join-Path $linkedArtifacts 'source-request.json') `
                -IncomingDirectory (Join-Path $runRoot '.incoming-reparse') `
                -DeliveryDirectory (Join-Path $runRoot 'verified-source') -Provider browser `
                -ReceiptPath (Join-Path $linkedArtifacts 'source-receipt.json') -RunRoot $runRoot -PassThru } |
            Should -Throw '*reparse*'
    }

    # Scenario: The fixed runner receives a source request whose Main file is known to be RAR.
    # Purpose: Validate identity and archive eligibility before acquiring the canonical MOD reservation.
    It 'InterT25_RejectsKnownUnsupportedArchivesBeforeReservation' {
        $repository = Join-Path $TestDrive 'known-rar-runner-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $requestPath = Join-Path $TestDrive 'known-rar-runner-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod-2.0.0.rar'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $result = & (Join-Path $scriptRoot 'mod-update.ps1') acquire-source `
            -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
            -RunId '44444444-5555-4666-8777-888888888888' `
            -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru

        $result.status | Should -Be 'waiting-user'
        $result.waitingReason.code | Should -Be 'unsupported_archive_format'
        Test-Path -LiteralPath (Join-Path $repository 'AI Auto Update/In Progress/.locks/mod') | Should -Be $false
    }

    # Scenario: The externally supplied request itself is under a junction and would otherwise return before reservation.
    # Purpose: Make runner preflight validate the physical request path before parsing or classifying the archive extension.
    It 'InterT27_RejectsAReparseExternalRequestBeforeRunnerPreflightReadsIt' {
        $repository = Join-Path $TestDrive 'reparse-preflight-repository'
        $outside = Join-Path $TestDrive 'reparse-preflight-outside'
        $linked = Join-Path $TestDrive 'reparse-preflight-link'
        New-Item -ItemType Directory -Path $repository, $outside -Force | Out-Null
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.rar'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outside 'source-request.json') -NoNewline
        New-Item -ItemType Junction -Path $linked -Target $outside | Out-Null

        { & (Join-Path $scriptRoot 'mod-update.ps1') acquire-source `
                -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -RunId '45454545-5555-4666-8777-888888888888' `
                -SourceRequestPath (Join-Path $linked 'source-request.json') `
                -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
            Should -Throw '*reparse*'
    }

    # Scenario: A same-run MOD reservation owner is corrupted while retaining the expected run ID.
    # Purpose: Resume only the exact canonical path, lock key, and state-path tuple instead of letting runId alone reauthorize the lock.
    It 'InterT28_RejectsACorruptedSameRunReservationOwnerTuple' {
        $repository = Join-Path $TestDrive 'reservation-owner-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $requestPath = Join-Path $TestDrive 'reservation-owner-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'
        $runId = '46464646-5555-4666-8777-888888888888'
        $first = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
            -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
            -Provider browser -PassThru
        $first.status | Should -Be 'waiting-user'
        $ownerPath = Join-Path $first.modLockPath 'owner.json'
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
        $owner.leaseMode | Should -Be 'reserved'
        $owner.reservationState | Should -Be 'waiting-user'
        $owner.reservationToken | Should -Match '^[0-9a-f]{32}$'
        $owner.workerToken | Should -BeNullOrEmpty
        $owner.workerId | Should -BeNullOrEmpty
        $owner.workerProcessStartTicks | Should -BeNullOrEmpty
        $owner.canonicalModRelativePath = 'Warhammer 40,000 DARKTIDE/mods/OtherMod'
        $owner | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerPath -NoNewline

        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
                -Provider browser -PassThru } | Should -Throw '*owner tuple changed*'
    }

    # Scenario: The process stops while preparing a new canonical MOD reservation before its owner tuple is published.
    # Purpose: Publish the fixed reservation only as one atomic directory rename so a crash cannot leave an ownerless lock that permanently blocks same-run recovery.
    It 'UnitT28A_PublishesOnlyCompleteModReservationsAtomically' {
        $runner = Get-Content -LiteralPath (Join-Path $scriptRoot 'mod-update.ps1') -Raw
        $start = $runner.IndexOf('function Enter-ModReservation')
        $end = $runner.IndexOf('function Assert-Schema15BaseLocalizationEligibility', $start)
        $start | Should -BeGreaterOrEqual 0
        $end | Should -BeGreaterThan $start
        $reservation = $runner.Substring($start, $end - $start)

        $reservation | Should -Match '\$preparedLockPath'
        $reservation | Should -Match 'Write-ModReservationOwner\s+-ModLockPath\s+\$preparedLockPath'
        $reservation | Should -Match '\[IO\.Directory\]::Move\(\$preparedLockPath, \[string\]\$Plan\.modLockPath\)'
        $reservation | Should -Not -Match 'New-Item\s+-ItemType\s+Directory\s+-Path\s+\(\[string\]\$Plan\.modLockPath\)'
    }

    # Scenario: Untrusted orchestration supplies a path-like MOD identity or an off-domain source page.
    # Purpose: Keep canonical MOD paths inside one directory and bind source identity to the official Nexus game page.
    It 'UnitT26_RejectsPathLikeModNamesAndOffDomainSourcePages' {
        $repository = Join-Path $TestDrive 'identity-boundary-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $requestPath = Join-Path $TestDrive 'off-domain-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://example.invalid/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'

        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory '../Escape' `
                -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
            Should -Throw '*single directory name*'
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'CON' `
                -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
            Should -Throw '*reserved Windows device name*'
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
            Should -Throw '*official Nexus MOD page*'
        $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
        $request.pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        $request.fileName = '../Escape.zip'
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
            Should -Throw '*single file name*'
        $request.fileName = 'NUL.zip'
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
            Should -Throw '*reserved Windows device name*'
    }

    # Scenario: An otherwise official Nexus page URL contains user-info, a signed query, or a fragment before the request is archived.
    # Purpose: Reject credential-bearing and non-canonical page URLs instead of persisting their raw bytes in run evidence.
    It 'UnitT29_RejectsCredentialBearingOrNonCanonicalSourcePageUrls' {
        $runner = Join-Path $scriptRoot 'mod-update.ps1'
        foreach ($case in @(
            [ordered]@{ name = 'user-info'; url = 'https://secret@www.nexusmods.com/warhammer40kdarktide/mods/123' },
            [ordered]@{ name = 'query'; url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123?key=signed-secret' },
            [ordered]@{ name = 'fragment'; url = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123#download' }
        )) {
            $repository = Join-Path $TestDrive "canonical-page-$($case.name)"
            New-Item -ItemType Directory -Path $repository -Force | Out-Null
            $requestPath = Join-Path $repository 'source-request.json'
            [ordered]@{
                schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
                version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = $case.url
            } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

            { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                    -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath -Provider browser -PassThru } |
                Should -Throw '*canonical page URL*'
        }
    }

    # Scenario: An existing signed-in browser session has completed a stable ZIP download for the exact requested Main file.
    # Purpose: Prove receipt generation, URL sanitization, SHA-256 binding, independent verification, and atomic delivery.
    It 'InterT30_VerifiesAndAtomicallyDeliversAStableZip' {
        $runRoot = Join-Path $TestDrive 'valid-zip'
        $incoming = Join-Path $runRoot '.incoming-test-run'
        $delivery = Join-Path $runRoot 'source'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod-2.0.0.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('ExampleMod/file.txt')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write('safe bytes') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose(); $stream.Dispose() }

        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1
            gameDomain = 'warhammer40kdarktide'
            modId = 123
            mainFileId = 456
            version = '2.0.0'
            fileName = 'ExampleMod-2.0.0.zip'
            pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
            officialSha256 = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $receiptPath = Join-Path $runRoot 'source-receipt.json'

        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath `
            -IncomingDirectory $incoming `
            -DeliveryDirectory $delivery `
            -Provider browser `
            -DownloadedFilePath $downloadPath `
            -ReceiptPath $receiptPath `
            -ObservationIntervalMilliseconds 0 `
            -PassThru

        $result.status | Should -Be 'delivered'
        Test-Path -LiteralPath $downloadPath | Should -Be $false
        Test-Path -LiteralPath $result.deliveredPath -PathType Leaf | Should -Be $true
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $receipt.schemaVersion | Should -Be 1
        $receipt.sourceRequest.mainFileId | Should -Be '456'
        $receipt.sourceUrl | Should -Be 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        $receipt.archiveFormat | Should -Be 'zip'
        $receipt.sha256 | Should -Match '^[0-9a-f]{64}$'

        $verification = & (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') `
            -ReceiptPath $receiptPath `
            -SourceRequestPath $requestPath `
            -PassThru
        $verification.result | Should -Be 'passed'

        $boundRequestBytes = [IO.File]::ReadAllBytes($requestPath)
        $credentialBearingRequest = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
        $credentialBearingRequest.pageUrl = 'https://secret@www.nexusmods.com/warhammer40kdarktide/mods/123?key=signed-secret#download'
        $credentialBearingRequest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $requestPath -NoNewline
        { & (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') `
                -ReceiptPath $receiptPath `
                -SourceRequestPath $requestPath `
                -PassThru } | Should -Throw '*canonical page URL*'
        [IO.File]::WriteAllBytes($requestPath, $boundRequestBytes)

        $boundReceiptBytes = [IO.File]::ReadAllBytes($receiptPath)
        $tamperedStabilityReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        $tamperedStabilityReceipt.stableObservations[0].size = 0
        $tamperedStabilityReceipt.stableObservations[1].size = 0
        $tamperedStabilityReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptPath -NoNewline
        { & (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') `
                -ReceiptPath $receiptPath `
                -SourceRequestPath $requestPath `
                -PassThru } | Should -Throw '*stability observations*'
        [IO.File]::WriteAllBytes($receiptPath, $boundReceiptBytes)

        $outsideArtifacts = Join-Path $TestDrive 'receipt-reparse-outside'
        $reparseRunRoot = Join-Path $TestDrive 'receipt-reparse-run'
        New-Item -ItemType Directory -Path $outsideArtifacts, $reparseRunRoot -Force | Out-Null
        Copy-Item -LiteralPath $receiptPath -Destination (Join-Path $outsideArtifacts 'source-receipt.json')
        Copy-Item -LiteralPath $requestPath -Destination (Join-Path $outsideArtifacts 'source-request.json')
        $linkedArtifacts = Join-Path $reparseRunRoot 'review-artifacts'
        New-Item -ItemType Junction -Path $linkedArtifacts -Target $outsideArtifacts | Out-Null
        { & (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') `
                -ReceiptPath (Join-Path $linkedArtifacts 'source-receipt.json') `
                -SourceRequestPath (Join-Path $linkedArtifacts 'source-request.json') `
                -RunRoot $reparseRunRoot -PassThru } | Should -Throw '*reparse*'

        $tamperedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        $tamperedReceipt.officialSha256 = $null
        $tamperedReceipt.officialHashPassed = $null
        $tamperedReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptPath -NoNewline
        { & (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') `
                -ReceiptPath $receiptPath `
                -SourceRequestPath $requestPath `
                -PassThru } | Should -Throw '*official SHA-256*'
    }

    # Scenario: A request serializer preserves the optional officialSha256 property with a JSON null value.
    # Purpose: Treat null exactly like an omitted optional hash across preflight, receipt creation, and verification.
    It 'InterT35_TreatsANullOptionalOfficialHashAsAbsent' {
        $runRoot = Join-Path $TestDrive 'null-official-hash'
        $incoming = Join-Path $runRoot '.incoming-test-run'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try { $null = $zip.CreateEntry('ExampleMod/file.txt') } finally { $zip.Dispose(); $stream.Dispose() }

        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
            officialSha256 = $null
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $receiptPath = Join-Path $runRoot 'source-receipt.json'

        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath -IncomingDirectory $incoming `
            -DeliveryDirectory (Join-Path $runRoot 'source') -Provider browser `
            -DownloadedFilePath $downloadPath -ReceiptPath $receiptPath `
            -ObservationIntervalMilliseconds 0 -PassThru

        $result.status | Should -Be 'delivered'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $receipt.officialSha256 | Should -BeNullOrEmpty
        $receipt.officialHashPassed | Should -BeNullOrEmpty
        (& (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') `
                -ReceiptPath $receiptPath -SourceRequestPath $requestPath -PassThru).result | Should -Be 'passed'
    }

    # Scenario: A browser download has a ZIP filename but RAR signature bytes.
    # Purpose: Retain post-download evidence while preventing delivery, claim, extraction, or installation.
    It 'InterT40_RetainsButDoesNotDeliverAnUnsupportedArchiveSignature' {
        $runRoot = Join-Path $TestDrive 'disguised-rar'
        $incoming = Join-Path $runRoot '.incoming-test-run'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip'
        [IO.File]::WriteAllBytes($downloadPath, [byte[]](0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00))
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $receiptPath = Join-Path $runRoot 'source-receipt.json'

        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath `
            -IncomingDirectory $incoming `
            -DeliveryDirectory (Join-Path $runRoot 'source') `
            -Provider browser `
            -DownloadedFilePath $downloadPath `
            -ReceiptPath $receiptPath `
            -ObservationIntervalMilliseconds 0 `
            -PassThru

        $result.status | Should -Be 'waiting-user'
        $result.waitingReason.code | Should -Be 'unsupported_archive_format'
        Test-Path -LiteralPath $downloadPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath $receiptPath -PathType Leaf | Should -Be $true
        (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).archiveFormat | Should -Be 'rar'
        Test-Path -LiteralPath (Join-Path $runRoot 'source') | Should -Be $false
    }

    # Scenario: The receiver persisted an unsupported-source receipt, then the process stopped before source-acquisition.json was written.
    # Purpose: Reverify and reattach the exact retained bytes and receipt for the same run instead of permanently stranding its reservation.
    It 'InterT41_RecoversARetainedReceiptBeforeItsAcquisitionRecordWasWritten' {
        $repository = Join-Path $TestDrive 'retained-receipt-recovery-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $runId = '41414141-5252-4636-8747-858585858585'
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/examplemod-41414141'
        $incoming = Join-Path $runRoot ".incoming-$runId"
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip'
        [IO.File]::WriteAllBytes($downloadPath, [byte[]](0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00))
        $requestPath = Join-Path $TestDrive 'retained-receipt-recovery-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'

        $first = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
            -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
            -Provider browser -DownloadedFilePath $downloadPath -ObservationIntervalMilliseconds 0 -PassThru
        $first.status | Should -Be 'waiting-user'
        $first.waitingReason.code | Should -Be 'unsupported_archive_format'
        Test-Path -LiteralPath $first.receiptPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath $first.acquisitionPath -PathType Leaf | Should -Be $true
        [IO.File]::Delete($first.acquisitionPath)
        $ownerPath = Join-Path $first.modLockPath 'owner.json'
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
        $owner.leaseMode = 'active'
        $owner.workerId = 999999
        $null = $owner.Remove('waitingReason')
        $owner | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ownerPath -NoNewline

        $recovered = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
            -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
            -Provider browser -DownloadedFilePath $downloadPath -ObservationIntervalMilliseconds 0 -PassThru

        $recovered.status | Should -Be 'waiting-user'
        $recovered.waitingReason.code | Should -Be 'unsupported_archive_format'
        $recovered.idempotent | Should -Be $true
        Test-Path -LiteralPath $recovered.acquisitionPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath $downloadPath -PathType Leaf | Should -Be $true
        $recoveredOwner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
        $recoveredOwner.leaseMode | Should -Be 'reserved'
        $recoveredOwner.workerId | Should -BeNullOrEmpty
        $recoveredOwner.waitingReason.code | Should -Be 'unsupported_archive_format'

        $recoveredAcquisitionBytes = [IO.File]::ReadAllBytes($recovered.acquisitionPath)
        $tamperedAcquisition = Get-Content -LiteralPath $recovered.acquisitionPath -Raw | ConvertFrom-Json -AsHashtable
        $tamperedAcquisition.result.retainedPath = Join-Path $incoming 'different-retained-path.zip'
        $tamperedAcquisition | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recovered.acquisitionPath -NoNewline
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
                -Provider browser -DownloadedFilePath $downloadPath -ObservationIntervalMilliseconds 0 -PassThru } |
            Should -Throw '*acquisition record changed*'
        [IO.File]::WriteAllBytes($recovered.acquisitionPath, $recoveredAcquisitionBytes)

        [IO.File]::WriteAllBytes($downloadPath, [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x00))
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' `
                -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
                -Provider browser -DownloadedFilePath $downloadPath -ObservationIntervalMilliseconds 0 -PassThru } |
            Should -Throw '*Retained source bytes*'
    }

    # Scenario: A browser still exposes a partial download extension.
    # Purpose: Keep incomplete files outside verification and distinguish retryable system waiting from user interaction.
    It 'UnitT50_IgnoresPartialBrowserDownloads' {
        $runRoot = Join-Path $TestDrive 'partial-download'
        $incoming = Join-Path $runRoot '.incoming-test-run'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip.crdownload'
        [IO.File]::WriteAllBytes($downloadPath, [byte[]](0x50, 0x4B, 0x03, 0x04))
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath `
            -IncomingDirectory $incoming `
            -DeliveryDirectory (Join-Path $runRoot 'source') `
            -Provider browser `
            -DownloadedFilePath $downloadPath `
            -ReceiptPath (Join-Path $runRoot 'source-receipt.json') `
            -ObservationIntervalMilliseconds 0 `
            -PassThru

        $result.status | Should -Be 'waiting-system'
        $result.waitingReason.code | Should -Be 'download_incomplete'
        Test-Path -LiteralPath $downloadPath -PathType Leaf | Should -Be $true
    }

    # Scenario: The API provider finished renaming its run-owned .part file, but the process stopped before returning the path to the receiver.
    # Purpose: Reattach the same run to the already completed incoming ZIP instead of requiring a replacement generation or download.
    It 'InterT52_RecoversACompletedApiDownloadBeforeStartingAnotherRequest' {
        $runRoot = Join-Path $TestDrive 'completed-api-download'
        $incoming = Join-Path $runRoot '.incoming-api-recovery'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try { $null = $zip.CreateEntry('ExampleMod/file.txt') } finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath -IncomingDirectory $incoming `
            -DeliveryDirectory (Join-Path $runRoot 'verified-source') -Provider api `
            -ReceiptPath (Join-Path $runRoot 'source-receipt.json') `
            -ApiDownloadUriEnvironmentVariable 'SYP91_TEST_MISSING_DOWNLOAD_URI' `
            -ApiKeyEnvironmentVariable 'SYP91_TEST_MISSING_API_KEY' `
            -ObservationIntervalMilliseconds 0 -PassThru

        $result.status | Should -Be 'delivered'
        Test-Path -LiteralPath $result.deliveredPath -PathType Leaf | Should -Be $true
    }

    # Scenario: An interrupted API stream left the fixed run-owned .part file behind before any receipt could be written.
    # Purpose: Retain the partial as evidence while freeing the deterministic .part name so the same run can retry instead of failing forever.
    It 'UnitT54_RetainsAStaleApiPartialBeforeTheSameRunRetries' {
        $runRoot = Join-Path $TestDrive 'stale-api-partial'
        $incoming = Join-Path $runRoot '.incoming-api-retry'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $partialPath = Join-Path $incoming 'ExampleMod.zip.part'
        [IO.File]::WriteAllBytes($partialPath, [byte[]](0x50, 0x4B, 0x03, 0x04))
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $result = & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
            -SourceRequestPath $requestPath -IncomingDirectory $incoming `
            -DeliveryDirectory (Join-Path $runRoot 'verified-source') -Provider api `
            -ReceiptPath (Join-Path $runRoot 'source-receipt.json') `
            -ApiDownloadUriEnvironmentVariable 'SYP91_TEST_MISSING_DOWNLOAD_URI' `
            -ApiKeyEnvironmentVariable 'SYP91_TEST_MISSING_API_KEY' `
            -ObservationIntervalMilliseconds 0 -PassThru

        $result.status | Should -Be 'waiting-system'
        $result.waitingReason.code | Should -Be 'api_download_uri_unavailable'
        Test-Path -LiteralPath $partialPath | Should -Be $false
        @(Get-ChildItem -LiteralPath $incoming -File -Filter '.retained-partial-*').Count | Should -Be 1
    }

    # Scenario: The apparent incoming directory is a junction to a different physical location.
    # Purpose: Reject reparse-root path indirection before stable-file verification or delivery.
    It 'InterT55_RejectsAReparseIncomingDirectory' {
        $runRoot = Join-Path $TestDrive 'reparse-incoming'
        $outside = Join-Path $TestDrive 'reparse-target'
        New-Item -ItemType Directory -Path $runRoot, $outside -Force | Out-Null
        $incoming = Join-Path $runRoot '.incoming-test-run'
        New-Item -ItemType Junction -Path $incoming -Target $outside | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try { $null = $zip.CreateEntry('ExampleMod/file.txt') } finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        { & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
                -SourceRequestPath $requestPath -IncomingDirectory $incoming `
                -DeliveryDirectory (Join-Path $runRoot 'source') -Provider browser `
                -DownloadedFilePath $downloadPath -ReceiptPath (Join-Path $runRoot 'source-receipt.json') `
                -ObservationIntervalMilliseconds 0 -PassThru } |
            Should -Throw '*reparse*'
    }

    # Scenario: The incoming leaf is regular, but one of its parent directories is swapped for a junction.
    # Purpose: Reject physical path escape through a parent reparse component before reading, moving, or writing source evidence.
    It 'InterT57_RejectsAReparseParentOfTheIncomingDirectory' {
        $runRoot = Join-Path $TestDrive 'reparse-incoming-parent'
        $outside = Join-Path $TestDrive 'reparse-parent-target'
        $redirected = Join-Path $runRoot 'redirected'
        New-Item -ItemType Directory -Path $runRoot, $outside -Force | Out-Null
        New-Item -ItemType Junction -Path $redirected -Target $outside | Out-Null
        $incoming = Join-Path $redirected '.incoming-test-run'
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try { $null = $zip.CreateEntry('ExampleMod/file.txt') } finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        { & (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') `
                -SourceRequestPath $requestPath -IncomingDirectory $incoming `
                -DeliveryDirectory (Join-Path $runRoot 'source') -Provider browser `
                -DownloadedFilePath $downloadPath -ReceiptPath (Join-Path $runRoot 'source-receipt.json') `
                -ObservationIntervalMilliseconds 0 -PassThru } |
            Should -Throw '*reparse*'
    }

    # Scenario: The fixed runner is extended for Schema 15 without removing the manual Schema 14 claim path.
    # Purpose: Route automatic acquisition through a resumable stage and bind claim to the independently verified receipt.
    It 'UnitT60_DeclaresSchema15AcquisitionAndReceiptBoundClaim' {
        $runner = Get-Content -LiteralPath (Join-Path $scriptRoot 'mod-update.ps1') -Raw
        $runner | Should -Match "'acquire-source'"
        $runner | Should -Match '\$SourceRequestPath'
        $runner | Should -Match '\$SourceReceiptPath'
        $runner | Should -Match 'Test-SourceReceipt\.ps1'
        $runner | Should -Match 'schemaVersion = if \(\$sourceReceipt\) \{ 15 \} else \{ 14 \}'
        $runner | Should -Match '(?s)elseif \(\$Command -eq ''run''\).*?Invoke-AcquireSource.*?Invoke-Claim'
    }

    # Scenario: The immutable base contains only a localization loader and Schema 15 source bytes have already been verified.
    # Purpose: Exclude TeamKills-style loader localization before branch or worktree creation instead of discovering it after install.
    It 'InterT72_ExcludesBaseLocalizationLoadersBeforeBranchCreation' {
        $repository = Join-Path $TestDrive 'loader-preflight-repository'
        $modRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods/TeamKills'
        New-Item -ItemType Directory -Path $modRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Loader Preflight Test'
        & git -C $repository config user.email 'loader-preflight@example.invalid'
        "mod:io_dofile('TeamKills/scripts/mods/TeamKills/localization/en')`nmod:io_dofile('TeamKills/scripts/mods/TeamKills/localization/zh-tw')" |
            Set-Content -LiteralPath (Join-Path $modRoot 'TeamKills_localization.lua') -NoNewline
        'return { helper = true }' | Set-Content -LiteralPath (Join-Path $modRoot 'localization.lua') -NoNewline
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'base loader'

        $runId = '22222222-3333-4444-8555-666666666666'
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/teamkills-22222222'
        $incoming = Join-Path $runRoot ".incoming-$runId"
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'TeamKills-2.0.0.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('TeamKills/file.txt')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write('new bytes') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 2; gameDomain = 'warhammer40kdarktide'; modId = 321; mainFileId = 654
            version = '2.0.0'; fileName = 'TeamKills-2.0.0.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/321'
            pageVersion = '2.0.0'; pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'; mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'
        $acquired = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'TeamKills' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -SkillSourcePinPath $script:skillSourcePinPath -ObservationIntervalMilliseconds 0 -PassThru

        { & $runner claim -RepositoryRoot $repository -ModDirectory 'TeamKills' -RunId $runId `
                -ArchivePath $acquired.deliveredPath -SourceRequestPath $acquired.sourceRequestPath `
                -SourceReceiptPath $acquired.receiptPath -BaseRef HEAD -PassThru } |
            Should -Throw '*AUTOMATION_EXCLUDED*localization_entry_is_loader*'
        @(& git -C $repository branch --list 'Update/*') | Should -BeNullOrEmpty
    }

    # Scenario: A caller supplies a source request directly to the fixed run command.
    # Purpose: Prove the automatic path chains acquire-source and receipt-bound claim without a second orchestration command.
    It 'InterT75_AutomaticRunChainsAcquisitionAndReceiptBoundClaim' {
        $repository = Join-Path $TestDrive 'automatic-run-repository'
        $modRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods/AutoMod'
        New-Item -ItemType Directory -Path $modRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Automatic Run Test'
        & git -C $repository config user.email 'automatic-run@example.invalid'
        'old bytes' | Set-Content -LiteralPath (Join-Path $modRoot 'file.txt') -NoNewline
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'base'

        $runId = '33333333-4444-4555-8666-777777777777'
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/automod-33333333'
        $incoming = Join-Path $runRoot ".incoming-$runId"
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'AutoMod-2.0.0.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('AutoMod/file.txt')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write('new bytes') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $TestDrive 'automatic-run-source-request.json'
        [ordered]@{
            schemaVersion = 2; gameDomain = 'warhammer40kdarktide'; modId = 777; mainFileId = 888
            version = '2.0.0'; fileName = 'AutoMod-2.0.0.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/777'
            pageVersion = '2.0.0'; pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'; mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $result = & (Join-Path $scriptRoot 'mod-update.ps1') run `
            -RepositoryRoot $repository -ModDirectory 'AutoMod' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -SkillSourcePinPath $script:skillSourcePinPath -ObservationIntervalMilliseconds 0 -BaseRef HEAD -Until source-verified -PassThru

        $result.result | Should -Be 'passed'
        $result.stage | Should -Be 'verify-source'
        $state = Get-Content -LiteralPath $result.statePath -Raw | ConvertFrom-Json
        $state.schemaVersion | Should -Be 15
        $state.sourceReceipt.sourceRequestPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $runRoot 'review-artifacts/source-request.json')))
        @($state.completedStages) | Should -Contain 'acquire-source'
        @($state.completedStages) | Should -Contain 'claim'
        @($state.completedStages) | Should -Contain 'verify-source'
    }

    # Scenario: A complete Schema 15 candidate has one unchanged localization file, but mutable state is edited to omit its localization record.
    # Purpose: Make the independent Gate cross-bind the unique localization file to the persisted manifest instead of skipping its byte checks.
    It 'InterT77_RejectsMutableStateThatOmitsTheUniqueLocalizationRecord' {
        $repository = Join-Path $TestDrive 'r'
        $modRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods/M'
        New-Item -ItemType Directory -Path $modRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Candidate Binding Test'
        & git -C $repository config user.email 'candidate-binding@example.invalid'
        $localizationText = 'return { hello = { en = "Hello", ["zh-tw"] = "哈囉" } }'
        [IO.File]::WriteAllText((Join-Path $modRoot 'M_localization.lua'), $localizationText, [Text.UTF8Encoding]::new($false))
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'base localization'

        $runId = '34343434-4545-4666-8777-898989898989'
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/m-34343434'
        $incoming = Join-Path $runRoot ".incoming-$runId"
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'M.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('M/M_localization.lua')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write($localizationText) } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $TestDrive 'r.json'
        [ordered]@{
            schemaVersion = 2; gameDomain = 'warhammer40kdarktide'; modId = 434; mainFileId = 545
            version = '2.0.0'; fileName = 'M.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/434'
            pageVersion = '2.0.0'; pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'; mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $candidateArchiveSha = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $candidateArchiveSize = (Get-Item -LiteralPath $downloadPath).Length
        (@(
            'https://www.nexusmods.com/warhammer40kdarktide/mods/434', '2.0.0',
            '2026-01-02T00:00:00.0000000+00:00', 'Main file ID: 545', 'M.zip'
        ) -join "`n") | Set-Content -LiteralPath (Join-Path $repository 'README.md') -NoNewline
        $candidateHashRoot = Join-Path $repository '.hash'
        New-Item -ItemType Directory -Path $candidateHashRoot -Force | Out-Null
        (@(
            'nexus_id=434', 'nexus_url=https://www.nexusmods.com/warhammer40kdarktide/mods/434',
            'nexus_page_version=2.0.0', 'nexus_last_updated=2026-01-02T00:00:00.0000000+00:00',
            'main_file_id=545', 'version=2.0.0', 'main_file_uploaded_at_utc=2026-01-01T00:00:00.0000000+00:00',
            'filename=M.zip', "size_bytes=$candidateArchiveSize", "sha256=$candidateArchiveSha", 'acquisition_method=nexus-browser'
        ) -join "`n") | Set-Content -LiteralPath (Join-Path $candidateHashRoot 'm.hash') -NoNewline
        & git -C $repository add README.md .hash/m.hash
        & git -C $repository commit --quiet -m 'base source metadata'

        $runner = Join-Path $scriptRoot 'mod-update.ps1'
        $sourceVerified = & $runner run -RepositoryRoot $repository -ModDirectory 'M' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -SkillSourcePinPath $script:skillSourcePinPath -ObservationIntervalMilliseconds 0 -BaseRef HEAD `
            -MetadataPath 'README.md', '.hash/m.hash' -Until source-verified -PassThru
        $sourceVerified.result | Should -Be 'passed'
        $statePath = $sourceVerified.statePath
        foreach ($stage in @('extract', 'install', 'localization', 'build-commits')) {
            $stageResult = & $runner $stage -RepositoryRoot $repository -StatePath $statePath -PassThru
            $stageResult.result | Should -Be 'passed'
        }

        $baselineStateBytes = [IO.File]::ReadAllBytes($statePath)
        $baselineValidation = & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru
        $baselineValidation.result | Should -Be 'passed'
        $reasonState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $reasonState.evidenceChain.c2Reason.disposition | Should -Be 'KEEP'
        $reasonState.evidenceChain.c3Reason.disposition | Should -Be 'KEEP'
        $reasonState.evidenceChain.c2Reason.code | Should -Be 'upstream-localization-unchanged'
        $reasonState.evidenceChain.c3Reason.code | Should -Be 'approved-localization-unchanged'

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        $reasonState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $reasonState.evidenceChain.c2Reason = $null
        $reasonState | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $statePath -NoNewline
        { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
            Should -Throw '*C2 reason*structured object*'

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        $reasonState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $reasonState.evidenceChain.c3Reason.code = 'self-declared-no-change'
        $reasonState | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $statePath -NoNewline
        { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
            Should -Throw '*C3 reason*unknown*'

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        $reasonState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $reasonState.evidenceChain.c2Reason.localizationManifestSha256 = '0' * 64
        $reasonState | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $statePath -NoNewline
        { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
            Should -Throw '*C2 reason*evidence*'

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        $metadataHashPath = Join-Path ((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).worktreePath) '.hash/m.hash'
        $metadataHashBytes = [IO.File]::ReadAllBytes($metadataHashPath)
        try {
            (Get-Content -LiteralPath $metadataHashPath -Raw).Replace('filename=M.zip', 'filename=M') |
                Set-Content -LiteralPath $metadataHashPath -NoNewline
            { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
                Should -Throw '*Metadata preview source file bytes changed*'
        }
        finally { [IO.File]::WriteAllBytes($metadataHashPath, $metadataHashBytes) }

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        @($state.localizationFiles).Count | Should -Be 1
        $acquisitionPath = [string]$state.sourceAcquisition.recordPath
        $baselineAcquisitionBytes = [IO.File]::ReadAllBytes($acquisitionPath)
        $alternatePinPath = Join-Path $runRoot 'review-artifacts/alternate-skill-source-pin.json'
        Copy-Item -LiteralPath $state.workflowSourcePinPath -Destination $alternatePinPath
        $alternatePinSha = (Get-FileHash -LiteralPath $alternatePinPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $acquisition = Get-Content -LiteralPath $acquisitionPath -Raw | ConvertFrom-Json -AsHashtable
        $acquisition.skillSourcePinPath = [IO.Path]::GetFullPath($alternatePinPath)
        $acquisition.skillSourcePinSha256 = $alternatePinSha
        $acquisition | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $acquisitionPath -NoNewline
        $state.sourceAcquisition.skillSourcePinPath = [IO.Path]::GetFullPath($alternatePinPath)
        $state.sourceAcquisition.skillSourcePinSha256 = $alternatePinSha
        $state.sourceAcquisition.recordSha256 = (Get-FileHash -LiteralPath $acquisitionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $statePath -NoNewline
        { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
            Should -Throw '*source acquisition Skill source pin*'

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        [IO.File]::WriteAllBytes($acquisitionPath, $baselineAcquisitionBytes)
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $acquisition = Get-Content -LiteralPath $acquisitionPath -Raw | ConvertFrom-Json -AsHashtable
        $acquisition.result.deliveredPath = Join-Path $runRoot 'verified-source/different.zip'
        $acquisition | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $acquisitionPath -NoNewline
        $state.sourceAcquisition.recordSha256 = (Get-FileHash -LiteralPath $acquisitionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $statePath -NoNewline
        { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
            Should -Throw '*source acquisition result changed*'

        [IO.File]::WriteAllBytes($statePath, $baselineStateBytes)
        [IO.File]::WriteAllBytes($acquisitionPath, $baselineAcquisitionBytes)
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.localizationFiles = @()
        $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $statePath -NoNewline

        { & (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -StatePath $statePath -PassThru } |
            Should -Throw '*exactly one localization*'
    }

    # Scenario: A browser-provided ZIP is acquired under a fixed run ID and then claimed by the same per-MOD reservation owner.
    # Purpose: Prove download verification occurs before worktree creation and the verified receipt survives in Schema 15 state.
    It 'InterT70_AcquiresThenClaimsTheVerifiedSourceInTheSameRun' {
        $repository = Join-Path $TestDrive 'runner-acquisition-repository'
        $modRoot = Join-Path $repository 'Warhammer 40,000 DARKTIDE/mods/ExampleMod'
        New-Item -ItemType Directory -Path $modRoot -Force | Out-Null
        & git -C $repository init --quiet
        & git -C $repository config user.name 'Source Runner Test'
        & git -C $repository config user.email 'source-runner@example.invalid'
        'old bytes' | Set-Content -LiteralPath (Join-Path $modRoot 'file.txt') -NoNewline
        & git -C $repository add .
        & git -C $repository commit --quiet -m 'base'

        $runId = '11111111-2222-4333-8444-555555555555'
        $runRoot = Join-Path $repository 'AI Auto Update/In Progress/examplemod-11111111'
        $incoming = Join-Path $runRoot ".incoming-$runId"
        New-Item -ItemType Directory -Path $incoming -Force | Out-Null
        $downloadPath = Join-Path $incoming 'ExampleMod-2.0.0.zip'
        $stream = [IO.File]::Open($downloadPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $entry = $zip.CreateEntry('ExampleMod/file.txt')
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write('new bytes') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose(); $stream.Dispose() }
        $requestPath = Join-Path $runRoot 'source-request.json'
        [ordered]@{
            schemaVersion = 2; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod-2.0.0.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
            pageVersion = '2.0.0'; pageUpdatedAt = '2026-01-02T00:00:00.0000000+00:00'; mainFileUploadedAtUtc = '2026-01-01T00:00:00.0000000+00:00'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'

        $acquired = & $runner acquire-source `
            -RepositoryRoot $repository `
            -ModDirectory 'ExampleMod' `
            -RunId $runId `
            -SourceRequestPath $requestPath `
            -SkillSourcePinPath $script:skillSourcePinPath `
            -Provider browser `
            -DownloadedFilePath $downloadPath `
            -ObservationIntervalMilliseconds 0 `
            -PassThru
        $relocatedRunRoot = Join-Path $TestDrive 'runner-reparse-run-root-target'
        Move-Item -LiteralPath $runRoot -Destination $relocatedRunRoot
        New-Item -ItemType Junction -Path $runRoot -Target $relocatedRunRoot | Out-Null
        try {
            { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' -RunId $runId `
                    -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
                    -Provider browser -DownloadedFilePath $downloadPath -ObservationIntervalMilliseconds 0 -PassThru } |
                Should -Throw '*reparse*'
        }
        finally {
            Remove-Item -LiteralPath $runRoot -Force
            Move-Item -LiteralPath $relocatedRunRoot -Destination $runRoot
        }
        $interruptedReceipt = Get-Content -LiteralPath $acquired.receiptPath -Raw | ConvertFrom-Json
        $interruptedReceipt.status = 'verified'
        $interruptedReceipt.deliveredAt = $null
        $interruptedReceipt.deliveredPath = $null
        $interruptedReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $acquired.receiptPath -NoNewline
        [IO.File]::Delete($acquired.acquisitionPath)
        $recoveredAcquisition = & $runner acquire-source `
            -RepositoryRoot $repository -ModDirectory 'ExampleMod' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -SkillSourcePinPath $script:skillSourcePinPath -ObservationIntervalMilliseconds 0 -PassThru
        $recoveredAcquisition.status | Should -Be 'delivered'
        $recoveredAcquisition.idempotent | Should -Be $true
        (Get-Content -LiteralPath $recoveredAcquisition.receiptPath -Raw | ConvertFrom-Json).status | Should -Be 'delivered'
        Test-Path -LiteralPath $recoveredAcquisition.acquisitionPath -PathType Leaf | Should -Be $true
        $acquired = $recoveredAcquisition
        $deliveredAcquisitionBytes = [IO.File]::ReadAllBytes($acquired.acquisitionPath)
        $tamperedDeliveredAcquisition = Get-Content -LiteralPath $acquired.acquisitionPath -Raw | ConvertFrom-Json -AsHashtable
        $tamperedDeliveredAcquisition.result.deliveredPath = Join-Path $runRoot 'verified-source/different.zip'
        $tamperedDeliveredAcquisition | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $acquired.acquisitionPath -NoNewline
        { & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'ExampleMod' -RunId $runId `
                -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
                -SkillSourcePinPath $script:skillSourcePinPath -ObservationIntervalMilliseconds 0 -PassThru } |
            Should -Throw '*acquisition record*'
        { & $runner claim -RepositoryRoot $repository -ModDirectory 'ExampleMod' -RunId $runId `
                -ArchivePath $acquired.deliveredPath -SourceRequestPath $acquired.sourceRequestPath `
                -SourceReceiptPath $acquired.receiptPath -BaseRef 'refs/heads/nonexistent-acquisition-result-test' -PassThru } |
            Should -Throw '*acquisition result*'
        [IO.File]::WriteAllBytes($acquired.acquisitionPath, $deliveredAcquisitionBytes)
        $boundRequestBytes = [IO.File]::ReadAllBytes($acquired.sourceRequestPath)
        $tamperedRequest = Get-Content -LiteralPath $acquired.sourceRequestPath -Raw | ConvertFrom-Json
        $tamperedRequest.mainFileId = 999
        $tamperedRequest | ConvertTo-Json | Set-Content -LiteralPath $acquired.sourceRequestPath -NoNewline
        { & $runner claim -RepositoryRoot $repository -ModDirectory 'ExampleMod' -RunId $runId `
                -ArchivePath $acquired.deliveredPath -SourceRequestPath $acquired.sourceRequestPath `
                -SourceReceiptPath $acquired.receiptPath -BaseRef HEAD -PassThru } |
            Should -Throw '*acquisition record*'
        [IO.File]::WriteAllBytes($acquired.sourceRequestPath, $boundRequestBytes)
        $claimed = & $runner claim `
            -RepositoryRoot $repository `
            -ModDirectory 'ExampleMod' `
            -RunId $runId `
            -ArchivePath $acquired.deliveredPath `
            -SourceRequestPath $acquired.sourceRequestPath `
            -SourceReceiptPath $acquired.receiptPath `
            -BaseRef HEAD `
            -PassThru

        $acquired.status | Should -Be 'delivered'
        $claimed.result | Should -Be 'passed'
        $state = Get-Content -LiteralPath $claimed.statePath -Raw | ConvertFrom-Json
        $state.schemaVersion | Should -Be 15
        $state.sourceReceipt.sha256 | Should -Be $acquired.receiptSha256
        $state.sourceAcquisition.recordPath | Should -Be $acquired.acquisitionPath
        $state.sourceAcquisition.recordSha256 | Should -Be $acquired.acquisitionSha256
        $state.sourceTuple.contract.runId | Should -Be $runId
        $state.sourceTuple.contract.acquisitionMethod | Should -Be 'nexus-browser'
        $state.sourceTuple.contract.nexus.mainFileId | Should -Be '456'
        $state.sourceTuple.contract.nexus.mainFileUploadedAtUtc | Should -Be '2026-01-01T00:00:00.0000000+00:00'
        $state.sourceTuple.contract.archive.fileName | Should -Be 'ExampleMod-2.0.0.zip'
        $state.sourceTuple.contract.archive.sha256 | Should -Be $state.archive.sha256
        $state.sourceTuple.contractSha256 | Should -Match '^[0-9a-f]{64}$'
        @($state.completedStages) | Should -Contain 'acquire-source'
        @($state.completedStages) | Should -Contain 'claim'
        (Get-Content -LiteralPath (Join-Path $state.modLockPath 'owner.json') -Raw | ConvertFrom-Json).runId | Should -Be $runId
    }

    # Scenario: A Schema 15 candidate reaches the independent Final Candidate Gate after the claimed archive has been copied into run ownership.
    # Purpose: Revalidate the immutable source request, receipt, preserved delivered source, archive SHA, and acquisition stage receipt before publication.
    It 'UnitT80_AddsIndependentSourceReceiptChecksToTheCandidateGate' {
        $validator = Get-Content -LiteralPath (Join-Path $scriptRoot 'Test-ModUpdateCandidate.ps1') -Raw
        $validator | Should -Match "Add-ValidationCheck -Name 'source-receipt'"
        $validator | Should -Match 'Test-SourceReceipt\.ps1'
        $validator | Should -Match 'sourceReceipt\.sha256'
        $validator | Should -Match 'sourceAcquisition\.recordSha256'
        $validator | Should -Match 'sourceReceipt = \$sourceReceiptEvidence'
        $validator | Should -Match "Add-ValidationCheck -Name 'reference-integrity'"
        $validator | Should -Match 'schema15Sha256'
        $validator | Should -Match 'RunRoot \$sourceRunRoot'
        $receiver = Get-Content -LiteralPath (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') -Raw
        $receiver | Should -Match '(?s)StatusCode\s+-in\s+@\(401, 403\).*waiting-user.*nexus_permission_required'
    }

    # Scenario: A stable-looking download is replaced between archive detection and hashing.
    # Purpose: Bind size, signature, and SHA-256 to one locked source stream after a fresh physical-path check.
    It 'UnitT85_BindsArchiveEvidenceToOneLockedSourceSnapshot' {
        $receiver = Get-Content -LiteralPath (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') -Raw
        $verifier = Get-Content -LiteralPath (Join-Path $scriptRoot 'Test-SourceReceipt.ps1') -Raw
        $runner = Get-Content -LiteralPath (Join-Path $scriptRoot 'mod-update.ps1') -Raw

        $receiver | Should -Match 'function Get-ArchiveEvidence'
        $receiver | Should -Match '\[IO\.File\]::Open\(\$Path, \[IO\.FileMode\]::Open, \[IO\.FileAccess\]::Read, \[IO\.FileShare\]::Read\)'
        $receiver | Should -Match '(?s)Assert-NoReparsePath -Path \$candidateFull.*\$archiveEvidence = Get-ArchiveEvidence -Path \$candidateFull'
        $receiver | Should -Not -Match '(?s)\$archiveFormat = Get-ArchiveFormat -Path \$candidateFull.*\$sha256 = Get-FileSha256 -Path \$candidateFull'
        $verifier | Should -Match 'function Get-ArchiveEvidence'
        $verifier | Should -Match '\[IO\.File\]::Open\(\$Path, \[IO\.FileMode\]::Open, \[IO\.FileAccess\]::Read, \[IO\.FileShare\]::Read\)'
        $verifier | Should -Not -Match '(?s)\$actualSha256 = Get-FileSha256 -Path \$deliveredPath.*Get-ArchiveFormat -Path \$deliveredPath'
        $runner | Should -Match '(?s)function Complete-InterruptedSourceDelivery.*\[IO\.File\]::Open\(\$candidate, \[IO\.FileMode\]::Open, \[IO\.FileAccess\]::Read, \[IO\.FileShare\]::Read\)'
    }

    # Scenario: Nexus responds to an authenticated API download with one or more redirects.
    # Purpose: Prevent the custom apikey header from following an unvalidated automatic redirect to another host.
    It 'UnitT87_ValidatesEveryApiDownloadRedirectBeforeSendingCredentials' {
        $receiver = Get-Content -LiteralPath (Join-Path $scriptRoot 'Receive-NexusMainFile.ps1') -Raw

        $receiver | Should -Match '\$handler\.AllowAutoRedirect\s*=\s*\$false'
        $receiver | Should -Match 'for \(\$redirectCount = 0; \$redirectCount -le 10; \$redirectCount\+\+\)'
        $receiver | Should -Match "\[int\]\`$response\.StatusCode -notin @\(301, 302, 303, 307, 308\)"
        $receiver | Should -Match "Assert-NexusDownloadUri -Uri \`$nextUri -Label 'API download redirect URI'"
        $receiver | Should -Match "Host\.EndsWith\('\.nexusmods\.com'"
    }

    # Scenario: A coordinator is asked to start duplicate MOD identities or more than four workers.
    # Purpose: Enforce one writer per canonical MOD and the global bounded-concurrency ceiling before any download starts.
    It 'UnitT90_RejectsDuplicateModsAndConcurrencyAboveFour' {
        $coordinator = Join-Path $scriptRoot 'Invoke-ModUpdateQueue.ps1'
        $queuePath = Join-Path $TestDrive 'duplicate-queue.json'
        [ordered]@{
            schemaVersion = 1
            items = @(
                [ordered]@{ modDirectory = 'ExampleMod'; sourceRequestPath = 'one.json'; provider = 'api' },
                [ordered]@{ modDirectory = 'examplemod'; sourceRequestPath = 'two.json'; provider = 'api' }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $queuePath -NoNewline

        { & $coordinator -RepositoryRoot $TestDrive -QueuePath $queuePath -ThrottleLimit 5 -PassThru } |
            Should -Throw '*between 1 and 4*'
        { & $coordinator -RepositoryRoot $TestDrive -QueuePath $queuePath -ThrottleLimit 2 -PassThru } |
            Should -Throw '*duplicate canonical MOD*'
        (Get-Content -LiteralPath $coordinator -Raw) | Should -Match 'ForEach-Object -Parallel'
    }

    # Scenario: One queued MOD has an invalid canonical identity while another independently reaches a structured waiting-user result.
    # Purpose: Contain a worker failure to its own item so one MOD cannot abort other distinct MOD acquisitions.
    It 'InterT95_ContainsOneWorkerFailureWithoutBlockingOtherMods' {
        $repository = Join-Path $TestDrive 'queue-failure-isolation-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $failedRequestPath = Join-Path $TestDrive 'queue-failed-request.json'
        $waitingRequestPath = Join-Path $TestDrive 'queue-waiting-request.json'
        foreach ($requestPath in @($failedRequestPath, $waitingRequestPath)) {
            [ordered]@{
                schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
                version = '2.0.0'; fileName = 'ExampleMod.rar'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
            } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        }
        $queuePath = Join-Path $TestDrive 'failure-isolation-queue.json'
        [ordered]@{
            schemaVersion = 1
            items = @(
                [ordered]@{ modDirectory = '../Escape'; sourceRequestPath = $failedRequestPath; provider = 'browser' },
                [ordered]@{ modDirectory = 'ExampleMod'; sourceRequestPath = $waitingRequestPath; provider = 'browser' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $queuePath -NoNewline

        $result = & (Join-Path $scriptRoot 'Invoke-ModUpdateQueue.ps1') `
            -RepositoryRoot $repository -QueuePath $queuePath `
            -SkillSourcePinPath $script:skillSourcePinPath -ThrottleLimit 2 -PassThru

        $result.result | Should -Be 'failed'
        @($result.results).Count | Should -Be 2
        @($result.results | Where-Object status -eq 'failed').Count | Should -Be 1
        @($result.results | Where-Object status -eq 'waiting-user').Count | Should -Be 1
    }

    # Scenario: Two distinct canonical MOD names collapse to the same filesystem-safe slug and use the same caller-supplied run ID.
    # Purpose: Keep their run roots, states, requests, receipts, and artifacts isolated even though their reservations have different lock keys.
    It 'InterT96_IsolatesSlugCollidingModIdentitiesWithTheSameRunId' {
        $repository = Join-Path $TestDrive 'slug-collision-repository'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $requestPath = Join-Path $TestDrive 'slug-collision-request.json'
        [ordered]@{
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'
        $runId = '96969696-5555-4666-8777-888888888888'

        $spaced = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'Foo Bar' `
            -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
            -Provider browser -PassThru
        $hyphenated = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'Foo-Bar' `
            -RunId $runId -SourceRequestPath $requestPath -SkillSourcePinPath $script:skillSourcePinPath `
            -Provider browser -PassThru

        $spaced.status | Should -Be 'waiting-user'
        $hyphenated.status | Should -Be 'waiting-user'
        $spaced.runRoot | Should -Not -Be $hyphenated.runRoot
        $spaced.plannedStatePath | Should -Not -Be $hyphenated.plannedStatePath
        $spaced.modLockPath | Should -Not -Be $hyphenated.modLockPath
        $spaced.sourceRequestPath | Should -Not -Be $hyphenated.sourceRequestPath
        Test-Path -LiteralPath $spaced.sourceRequestPath -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath $hyphenated.sourceRequestPath -PathType Leaf | Should -Be $true
    }
}
