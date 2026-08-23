Describe 'Schema 15 source acquisition contract' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $scriptRoot = Join-Path $repoRoot '.agents/skills/auto-update-darktide-mod/scripts'
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
            -SourceRequestPath $requestPath -Provider browser -PassThru

        $result.status | Should -Be 'waiting-user'
        $result.waitingReason.code | Should -Be 'unsupported_archive_format'
        Test-Path -LiteralPath (Join-Path $repository 'AI Auto Update/In Progress/.locks/mod') | Should -Be $false
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
            pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123?key=must-not-persist#download'
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
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 321; mainFileId = 654
            version = '2.0.0'; fileName = 'TeamKills-2.0.0.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/321'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'
        $acquired = & $runner acquire-source -RepositoryRoot $repository -ModDirectory 'TeamKills' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -ObservationIntervalMilliseconds 0 -PassThru

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
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 777; mainFileId = 888
            version = '2.0.0'; fileName = 'AutoMod-2.0.0.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/777'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline

        $result = & (Join-Path $scriptRoot 'mod-update.ps1') run `
            -RepositoryRoot $repository -ModDirectory 'AutoMod' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -ObservationIntervalMilliseconds 0 -BaseRef HEAD -Until source-verified -PassThru

        $result.result | Should -Be 'passed'
        $result.stage | Should -Be 'verify-source'
        $state = Get-Content -LiteralPath $result.statePath -Raw | ConvertFrom-Json
        $state.schemaVersion | Should -Be 15
        $state.sourceReceipt.sourceRequestPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $runRoot 'review-artifacts/source-request.json')))
        @($state.completedStages) | Should -Contain 'acquire-source'
        @($state.completedStages) | Should -Contain 'claim'
        @($state.completedStages) | Should -Contain 'verify-source'
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
            schemaVersion = 1; gameDomain = 'warhammer40kdarktide'; modId = 123; mainFileId = 456
            version = '2.0.0'; fileName = 'ExampleMod-2.0.0.zip'; pageUrl = 'https://www.nexusmods.com/warhammer40kdarktide/mods/123'
        } | ConvertTo-Json | Set-Content -LiteralPath $requestPath -NoNewline
        $runner = Join-Path $scriptRoot 'mod-update.ps1'

        $acquired = & $runner acquire-source `
            -RepositoryRoot $repository `
            -ModDirectory 'ExampleMod' `
            -RunId $runId `
            -SourceRequestPath $requestPath `
            -Provider browser `
            -DownloadedFilePath $downloadPath `
            -ObservationIntervalMilliseconds 0 `
            -PassThru
        $recoveredAcquisition = & $runner acquire-source `
            -RepositoryRoot $repository -ModDirectory 'ExampleMod' -RunId $runId `
            -SourceRequestPath $requestPath -Provider browser -DownloadedFilePath $downloadPath `
            -ObservationIntervalMilliseconds 0 -PassThru
        $recoveredAcquisition.status | Should -Be 'delivered'
        $recoveredAcquisition.idempotent | Should -Be $true
        $recoveredAcquisition.receiptSha256 | Should -Be $acquired.receiptSha256
        $recoveredAcquisition.acquisitionSha256 | Should -Be $acquired.acquisitionSha256
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
}
