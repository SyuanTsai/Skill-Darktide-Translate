# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:PreparePath = Join-Path $script:RepositoryRoot 'scripts/Prepare-PesterRuntime.ps1'
    $script:Lock = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'config/pester-6.2.0-closure.lock.json') -Raw | ConvertFrom-Json -Depth 20
    $script:PowerShellPath = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    $script:LoadedPester = @(Get-Module Pester | Where-Object Version -eq ([version]'6.2.0')) | Select-Object -First 1
    if ($null -eq $script:LoadedPester) { throw 'Prepare-PesterRuntime behavior tests require the explicit Pester 6.2.0 host.' }
    $script:AuthorityRoot = [Environment]::GetEnvironmentVariable('DT_TEST_AUTHORITY_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($script:AuthorityRoot)) { $script:AuthorityRoot = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '../mainbase')) }
    $manifest = Join-Path $script:AuthorityRoot 'scripts/platform-runtime.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'd3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9') {
        $sourceRepository = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot '../mainbase'))
        $archive = Join-Path $TestDrive 'authority-fbdc793.zip'
        $script:AuthorityRoot = Join-Path $TestDrive 'authority-fbdc793'
        & git -C $sourceRepository archive --format=zip --output=$archive fbdc793c1c439b15c6def97d53111f250d0ff4db
        if ($LASTEXITCODE -ne 0) { throw 'Could not materialize the offline authority fixture.' }
        Expand-Archive -LiteralPath $archive -DestinationPath $script:AuthorityRoot
    }
    Import-Module -Name (Join-Path $script:RepositoryRoot 'scripts/CorePesterIntegrity.psm1') -Force
    $script:PlatformRuntime = Import-CorePesterAuthorityPlatformRuntime -AuthorityRoot $script:AuthorityRoot -AuthorityRevision 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
    Import-Module -ModuleInfo $script:PlatformRuntime -Force

    function New-TestPrivateDirectory {
        param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$RelativePath)
        $current=$Root; $lease=$null
        foreach($segment in $RelativePath.Replace('\','/').Split('/',[StringSplitOptions]::RemoveEmptyEntries)){
            if($null-ne$lease){$lease.Dispose()}
            $lease=Open-PlatformDirectory -Root $current -RelativePath $segment -CreatePrivate
            $current=Join-Path $current $segment
        }
        if($null-ne$lease){$lease.Dispose()}
        return $current
    }

    function New-PesterPackageFixture {
        param([Parameter(Mandatory)][string] $Path, [ValidateSet('valid','hash-mismatch')][string] $Variant = 'valid')
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                $regular = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]::Parse('81A40000', [Globalization.NumberStyles]::HexNumber)), 0)
                foreach ($payload in $script:Lock.modulePayload) {
                    $entry = $zip.CreateEntry([string]$payload.path); $entry.ExternalAttributes = $regular
                    $target = $entry.Open()
                    try {
                        $bytes = if ($Variant -ceq 'hash-mismatch' -and [string]$payload.path -ceq 'Pester.psm1') {
                            [Text.Encoding]::UTF8.GetBytes('tampered')
                        }
                        else { [IO.File]::ReadAllBytes((Join-Path $script:LoadedPester.ModuleBase ([string]$payload.path))) }
                        $target.Write($bytes, 0, $bytes.Length)
                    }
                    finally { $target.Dispose() }
                }
                foreach ($name in @('_rels/.rels','[Content_Types].xml','package/services/metadata/core-properties/nuget.psmdcp')) {
                    $entry=$zip.CreateEntry($name); $entry.ExternalAttributes=$regular; $target=$entry.Open(); try{$target.WriteByte(0x20)}finally{$target.Dispose()}
                }
                $entry=$zip.CreateEntry('Pester.nuspec'); $entry.ExternalAttributes=$regular; $target=$entry.Open()
                try { $bytes=[Text.Encoding]::UTF8.GetBytes('<package><metadata><id>Pester</id><version>6.2.0</version></metadata></package>'); $target.Write($bytes,0,$bytes.Length) }
                finally { $target.Dispose() }
            }
            finally { $zip.Dispose() }
        }
        finally { $stream.Dispose() }
    }

    function Invoke-PrepareFixture {
        param([string] $Variant='valid', [string] $CacheKind='none', [switch] $PrecreateDestination, [switch] $FailAfterDestination)
        $ownedLeaf=[guid]::NewGuid().ToString('N')
        $owned=[IO.Path]::GetFullPath([string](New-PlatformPrivateRoot -Parent $TestDrive -Leaf $ownedLeaf))
        $package = Join-Path $owned 'fixture.nupkg'
        New-PesterPackageFixture -Path $package -Variant $Variant
        $destination = Join-Path $owned 'Modules/Pester/6.2.0'
        [void](New-TestPrivateDirectory -Root $owned -RelativePath 'Modules')
        if ($PrecreateDestination) {
            [void](New-TestPrivateDirectory -Root (Join-Path $owned 'Modules') -RelativePath 'Pester/6.2.0')
            $parent=Open-PlatformDirectory -Root $destination -RootOnly
            try{$file=Open-PlatformFile -ParentLease $parent -Leaf 'occupied.txt' -Access ReadWrite -CreateMode CreateNew; try{$file.WriteNewBytes([Text.Encoding]::UTF8.GetBytes('occupied'))}finally{$file.Dispose()}}finally{$parent.Dispose()}
        }
        $cache = ''
        if ($CacheKind -ceq 'missing') { $cache = Join-Path $owned 'missing-cache' }
        elseif ($CacheKind -ceq 'polluted') {
            $cache = New-TestPrivateDirectory -Root $owned -RelativePath 'polluted-cache'; [IO.File]::WriteAllText((Join-Path $cache 'Pester.6.2.0.nupkg'),'polluted')
        }
        $oldOwned=$env:RUN_OWNED_ROOT; $oldMode=$env:DT_PREPARE_PESTER_TEST_MODE
        try {
            $env:RUN_OWNED_ROOT=$owned; $env:DT_PREPARE_PESTER_TEST_MODE='1'
            $arguments=@('-NoProfile','-NonInteractive','-File',$script:PreparePath,'-RuntimeExecutable',$script:PowerShellPath,'-OwnedRoot',$owned,
                '-AuthorityRepositoryRoot',$script:AuthorityRoot,'-AuthorityRevision','fbdc793c1c439b15c6def97d53111f250d0ff4db',
                '-FixturePackagePath',$package,'-FixtureDestinationModuleRoot',$destination)
            if ($cache) { $arguments += @('-PackageCacheRoot',$cache) }
            if ($FailAfterDestination) { $arguments += '-FixtureFailAfterDestination' }
            $output=@(& $script:PowerShellPath @arguments 2>&1)
            return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=($output -join "`n");Owned=$owned;Destination=$destination}
        }
        finally { $env:RUN_OWNED_ROOT=$oldOwned; $env:DT_PREPARE_PESTER_TEST_MODE=$oldMode }
    }
}

Describe 'Prepare-PesterRuntime offline behavior' {
    # Scenario: A reviewed package fixture contains the complete pinned Pester closure.
    # Purpose: Exercise installation and post-copy closure verification without network access.
    It 'InterT10_installs_and_verifies_the_valid_offline_closure' {
        $result=Invoke-PrepareFixture
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'exact closure installed'
        Test-Path -LiteralPath (Join-Path $result.Destination 'Pester.psd1') -PathType Leaf | Should -BeTrue
    }

    # Scenario: The package identity is valid ZIP data but one pinned payload hash differs.
    # Purpose: Reject hash or identity drift before publishing a successful runtime receipt.
    It 'InterT20_rejects_offline_hash_or_identity_mismatch' {
        $result=Invoke-PrepareFixture -Variant hash-mismatch
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'does not match the complete reviewed lock'
    }

    # Scenario: A run-owned cache is missing or contains a polluted archive, while the offline acquisition fixture remains valid.
    # Purpose: Disable and log the cache instead of trusting or repairing it, then continue from the verified acquisition path.
    It 'InterT30_disables_and_logs_<CacheKind>_cache' -ForEach @(@{CacheKind='missing'},@{CacheKind='polluted'}) {
        $result=Invoke-PrepareFixture -CacheKind $CacheKind
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'Pester package cache disabled:'
    }

    # Scenario: The exact final Pester destination is already non-empty.
    # Purpose: Preserve create-only publication and refuse overwrite or reuse.
    It 'InterT40_rejects_a_nonempty_destination' {
        $result=Invoke-PrepareFixture -PrecreateDestination
        $result.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $result.Destination 'occupied.txt') -PathType Leaf | Should -BeTrue
    }

    # Scenario: A failure is injected immediately after the unique final destination is created.
    # Purpose: Follow the P11-before design: fail closed, retain failed evidence, and never attempt unsafe tree cleanup or reuse.
    It 'InterT50_retains_the_failed_destination_when_cleanup_cannot_be_proven' {
        $result=Invoke-PrepareFixture -FailAfterDestination
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'retained as failed run evidence and must not be reused'
        Test-Path -LiteralPath $result.Destination -PathType Container | Should -BeTrue
    }
}
