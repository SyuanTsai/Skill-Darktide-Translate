# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Desktop archive reader' {
    BeforeAll {
        $source = Join-Path $PSScriptRoot '../skills/auto-update-darktide-mod/scripts'
        $scripts = Join-Path $TestDrive 'scripts'
        New-Item -ItemType Directory $scripts | Out-Null
        foreach ($leaf in @('DesktopArchive.ps1','DarktideArchiveCrc.cs','PathSafety.psm1','Test-SourceReceipt.ps1','Receive-NexusMainFile.ps1')) {
            Copy-Item (Join-Path $source $leaf) $scripts
        }
        Copy-Item (Join-Path $source 'rar_reader.py') (Join-Path $scripts 'reader_under_test.py')
        Copy-Item (Join-Path $PSScriptRoot 'support/rar_sdk_fixture.py') (Join-Path $scripts 'rar_reader.py')
        Import-Module (Join-Path $scripts 'PathSafety.psm1') -Force
        . (Join-Path $scripts 'DesktopArchive.ps1')
        function Write-RarFixture($Path, [array]$Rows) {
            $json = ConvertTo-Json -InputObject $Rows -Compress
            [IO.File]::WriteAllBytes($Path, [byte[]](@(82,97,114,33,26,7,1,0) + [Text.Encoding]::UTF8.GetBytes($json)))
            (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()
        }
    }
    # Scenario: The reader receives a file with an unsafe or ambiguous path.
    # Purpose: Reject the entire manifest before creating any destinations.
    It 'UnitT10_RejectsUnsafeManifestPaths' {
        foreach ($name in @('../escape', 'Mod//file', 'Mod/NUL.txt', 'Mod/bad*', 'Mod/./file', '/absolute')) {
            $entry = @{path=$name; size=1; compressedSize=1; externalAttributes=0; directory=$false}
            { Assert-DesktopArchiveManifest @($entry) } | Should -Throw
        }
    }
    # Scenario: Several entries map to overlapping portable filesystem names.
    # Purpose: Prevent parent aliases and file/directory conflicts on replay.
    It 'UnitT20_RejectsCollidingAncestorNames' {
        foreach ($pair in @(@('Mod/a', 'mod/b'), @('Mod/a', 'Mod/a/b'))) {
            $entries = foreach ($name in $pair) { @{path=$name; size=1; compressedSize=1; externalAttributes=0; directory=$false} }
            { Assert-DesktopArchiveManifest $entries } | Should -Throw
        }
    }

    # Scenario: Headers claim negative, highly compressed, oversized or excessive total payloads.
    # Purpose: Apply the same limits to both formats before opening output files.
    It 'UnitT25_RejectsItemRatioAndAggregateLimitViolations' {
        foreach ($sizes in @(@(-1L,1L),@((1GB+1L),1GB),@(1001L,1L),@(1L,0L))) {
            $entry = @{path='Mod/a'; directory=$false; size=$sizes[0]; compressedSize=$sizes[1]; externalAttributes=0}
            { Assert-DesktopArchiveManifest @($entry) } | Should -Throw '*limit*'
        }
        $entries = @(foreach ($n in 1..5) {
            @{path="Mod/$n"; directory=$false; size=1GB; compressedSize=1GB; externalAttributes=0}
        })
        { Assert-DesktopArchiveManifest $entries } | Should -Throw '*total size limit*'
    }

    # Scenario: A ZIP-only historical unsupported receipt recorded seven bytes of a truncated RAR5 marker.
    # Purpose: Replay the old classification exclusively for retained evidence while denying new intake.
    It 'UnitT27_PreservesLegacyUnsupportedSignatureClassification' {
        $header = [byte[]](82,97,114,33,26,7,1)
        Get-DesktopArchiveSignature $header 7 -LegacyUnsupportedRar | Should -BeExactly rar
        Get-DesktopArchiveSignature $header 7 | Should -BeExactly unknown
    }

    # Scenario: Evidence is a completed read, while a separate source owner retains
    # the one verified descriptor used by a later ZIP read or verified delivery.
    It 'UnitT28_SeparatesArchiveEvidenceFromVerifiedSourceOwnership' {
        $file = Join-Path $TestDrive 'owned-source.zip'
        [IO.File]::WriteAllBytes($file, [byte[]](80,75,5,6,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        $evidence = Get-DesktopArchiveEvidence -Path $file
        $evidence.ContainsKey('stream') | Should -BeFalse
        $source = Open-DesktopArchiveSource -Path $file
        try {
            $source.evidence.sha256 | Should -BeExactly $evidence.sha256
            $source.stream.Position | Should -Be 0
            $source.stream.ReadByte() | Should -Be 80
        } finally { Close-DesktopArchiveSource $source }
    }

    # Scenario: Extraction creates only the already-contained destination and the
    # native reader resolves its production DLL without process environment input.
    It 'UnitT29_UsesExplicitFileEnumsAndAHostOwnedUnrarLocation' {
        $archive = Get-Content -LiteralPath (Join-Path $source 'DesktopArchive.ps1') -Raw
        $reader = Get-Content -LiteralPath (Join-Path $source 'rar_reader.py') -Raw
        $archive | Should -Match '(?s)\[IO\.File\]::Open\(\$destination,\s*\[IO\.FileMode\]::CreateNew,\s*\[IO\.FileAccess\]::Write,\s*\[IO\.FileShare\]::None\)'
        $archive | Should -Not -Match "Open\(\$destination,'CreateNew'"
        $reader | Should -Not -Match 'os\.environ'
        $reader | Should -Not -Match '\brequests\b'
        $reader | Should -Match 'SHGetKnownFolderPath'
    }

    # Scenario: An opaque RAR from the offline SDK fixture is acquired from the browser inbox.
    # Purpose: Bind replay, listing and extracted bytes to the original format, filename, size and SHA.
    It 'InterT30_RoundTripsRarIdentityAndStreamsItsPayload' {
        $root = Join-Path $TestDrive 'run'
        $incoming = Join-Path $root '.incoming-run'
        $null = New-Item -ItemType Directory $incoming -Force
        $file = Join-Path $incoming 'ExampleMod.rar'
        $sha = Write-RarFixture $file @(@{name='ExampleMod/file.txt'})
        $size = (Get-Item $file).Length
        $request = Join-Path $root 'request.json'
        @{schemaVersion=1; gameDomain='warhammer40kdarktide'; modId=160; mainFileId=8444; version='1.9.6'
          fileName='ExampleMod.rar'; pageUrl='https://www.nexusmods.com/warhammer40kdarktide/mods/160'; officialSha256=$sha} |
            ConvertTo-Json | Set-Content $request
        $receipt = Join-Path $root 'receipt.json'
        $result = & (Join-Path $scripts 'Receive-NexusMainFile.ps1') -SourceRequestPath $request -ReceiptPath $receipt `
            -IncomingDirectory $incoming -DeliveryDirectory (Join-Path $root 'verified-source') -Provider browser `
            -DownloadedFilePath $file -ObservationIntervalMilliseconds 0 -PassThru
        $result.status | Should -BeExactly 'delivered'
        $evidence = Get-Content $receipt -Raw | ConvertFrom-Json
        $evidence.archiveFormat | Should -BeExactly rar
        $evidence.filename | Should -BeExactly 'ExampleMod.rar'
        $evidence.size | Should -Be $size
        $evidence.sha256 | Should -BeExactly $sha
        (& (Join-Path $scripts 'Test-SourceReceipt.ps1') -ReceiptPath $receipt -SourceRequestPath $request -PassThru).result | Should -Be 'passed'
        $reader = Open-DesktopArchive $result.deliveredPath $sha rar
        try {
            $stage = (New-Item -ItemType Directory (Join-Path $root 'stage')).FullName
            $hashes = @{}
            Read-DesktopArchiveData $reader $stage -Hashes $hashes
            Assert-DesktopExtractionTree $reader.entries $stage $hashes
            [IO.File]::ReadAllText((Join-Path $stage 'ExampleMod/file.txt')) | Should -BeExactly abc
            [IO.File]::WriteAllText((Join-Path $stage 'ExampleMod/file.txt'), 'xyz')
            { Assert-DesktopExtractionTree $reader.entries $stage $hashes } | Should -Throw '*bytes differ*'
        } finally { Close-DesktopArchive $reader }
        $original = Get-Content $receipt -Raw
        $original -replace '("archiveFormat"\s*:\s*)"rar"', '$1"zip"' | Set-Content $receipt
        { & (Join-Path $scripts 'Test-SourceReceipt.ps1') -ReceiptPath $receipt -SourceRequestPath $request -PassThru } | Should -Throw '*format*'
    }

    # Scenario: Archive bytes no longer match the request, or the installed decoder cannot load.
    # Purpose: Both conditions must stop verification before any receipt or output is produced.
    It 'InterT35_FailsClosedOnChecksumOrDependencyFailure' {
        . (Join-Path $source 'DesktopArchive.ps1')
        $file = Join-Path $TestDrive 'unavailable.rar'
        $sha = Write-RarFixture $file @(@{name='Mod/file'})
        { Open-DesktopArchive $file ('0' * 64) rar } | Should -Throw '*SHA-256*'
        { Open-DesktopArchive $file $sha rar } | Should -Throw '*Cannot load trusted UnRAR SDK*'
    }

    # Scenario: A later RAR header is unsafe or reports a filesystem redirection.
    # Purpose: Complete manifest inspection before the decoder receives permission to stream.
    It 'InterT40_RejectsTraversalAndRedirectionBeforeStreaming' {
        foreach ($bad in @(@{name='../outside'}, @{name='Mod/link'; redirect=4})) {
            $file = Join-Path $TestDrive 'unsafe.rar'
            $sha = Write-RarFixture $file @(@{name='Mod/good'}, $bad)
            { Open-DesktopArchive $file $sha rar } | Should -Throw
        }
    }

    # Scenario: A decoder returns fewer or more bytes than listed, or a final integrity error.
    # Purpose: A successful manifest cannot mask incomplete or corrupt decompression.
    It 'InterT50_RejectsShortLongAndFailedDecoderOutput' {
        foreach ($row in @(@{name='Mod/a'; size=4}, @{name='Mod/a'; size=2}, @{name='Mod/a'; error=12}, @{name='Mod/a'; crc=0})) {
            $file = Join-Path $TestDrive 'invalid.rar'
            $sha = Write-RarFixture $file @($row)
            { Test-DesktopRarData $file $sha } | Should -Throw
        }
    }

    # Scenario: The fixed extract stage writes a first file and then the decoder fails integrity.
    # Purpose: Verify that the stage removes its private partial tree and preserves previous output.
    It 'InterT55_CleansFailedExtractionAndPreservesPublishedTree' {
        $tokens = $errors = $null
        $runner = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'mod-update.ps1'),[ref]$tokens,[ref]$errors)
        foreach ($name in @('Invoke-Extract','Assert-NoReparsePath','Assert-NoReparseTree','Remove-DirectoryTreeWithHeartbeat')) {
            $node = $runner.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
            . ([scriptblock]::Create($node.Extent.Text))
        }
        function Get-CompletedStageResult {}
        function Start-Stage {}
        function Assert-LockOwner {}
        function Import-SecurityOverrides {}
        function Update-ActiveReservationHeartbeat {}
        function Update-ActiveSharedCoordinationHeartbeat {}
        $SecurityOverridePath = $null
        $run = (New-Item -ItemType Directory (Join-Path $TestDrive 'retry')).FullName
        $published = New-Item -ItemType Directory (Join-Path $run 'staging/extracted') -Force
        $file = Join-Path $run 'partial.rar'
        $sha = Write-RarFixture $file @(@{name='Mod/first'},@{name='Mod/second'; error=12})
        $state = @{runRoot=$run; repoModDirectory='Mod'; archive=@{path=$file; sha256=$sha; format='rar'}}
        { Invoke-Extract $state } | Should -Throw '*RAR integrity*'
        @(Get-ChildItem -Force (Join-Path $run 'staging')).Count | Should -Be 1
        Test-Path -LiteralPath $published.FullName | Should -BeTrue
    }

    # Scenario: A stored ZIP member changes while the central directory retains its CRC.
    # Purpose: Recomputed archive SHA alone cannot prove entry-level integrity.
    It 'InterT60_RejectsCorruptZipAndReadsLegacyFormat' {
        $file = Join-Path $TestDrive 'legacy.zip'
        $zip = [IO.Compression.ZipFile]::Open($file,'Create')
        try {
            $stream = $zip.CreateEntry('Mod/a','NoCompression').Open()
            try { $stream.WriteByte(66) } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        $format = Get-StateArchiveFormat @{path=$file}
        $format | Should -BeExactly zip
        $reader = Open-DesktopArchive $file (Get-FileHash $file).Hash.ToLowerInvariant() $format
        try { Read-DesktopArchiveData $reader } finally { Close-DesktopArchive $reader }
        $bytes = [IO.File]::ReadAllBytes($file)
        $dataOffset = 30 + [BitConverter]::ToUInt16($bytes,26) + [BitConverter]::ToUInt16($bytes,28)
        $bytes[$dataOffset] = 67
        [IO.File]::WriteAllBytes($file,$bytes)
        $reader = Open-DesktopArchive $file (Get-FileHash $file).Hash.ToLowerInvariant() zip
        try { { Read-DesktopArchiveData $reader } | Should -Throw } finally { Close-DesktopArchive $reader }
    }
}
