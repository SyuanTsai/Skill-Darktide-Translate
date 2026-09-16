# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Installed closure ordering' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Validate.ps1'
        $tokens = $null
        $parseErrors = $null
        $script:ValidatorAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:ValidatorPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            throw "Validate.ps1 parse failed: $($parseErrors | ForEach-Object Message -join '; ')"
        }
        $script:SortAst = $script:ValidatorAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Sort-InstalledClosureEntriesByOrdinalPath'
        }, $true)
    }

    It 'uses the source helper to preserve Ordinal canonical bytes and reject duplicate paths' {
        $script:SortAst | Should -Not -BeNullOrEmpty
        $helper = $script:SortAst.Extent.Text
        $helper | Should -Match '\[Array\]::Sort\(\$orderedPaths, \[StringComparer\]::Ordinal\)'
        $helper | Should -Not -Match '\.Insert\('

        . ([scriptblock]::Create($helper))
        $entries = @(
            [pscustomobject]@{ path = 'zeta/file'; sha256 = ('z' * 64) },
            [pscustomobject]@{ path = 'alpha/file'; sha256 = ('a' * 64) },
            [pscustomobject]@{ path = 'A/file'; sha256 = ('A' * 64) },
            [pscustomobject]@{ path = 'alpha/other'; sha256 = ('b' * 64) },
            [pscustomobject]@{ path = 'unicode/é'; sha256 = ('e' * 64) }
        )
        $actual = (Sort-InstalledClosureEntriesByOrdinalPath -Entries $entries).ToArray()
        $expectedPaths = [string[]]@($entries | ForEach-Object { [string]$_.path })
        [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
        (@($actual | ForEach-Object { [string]$_.path }) -join "`n") | Should -Be ($expectedPaths -join "`n")

        $canonical = ($actual | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
        $digest | Should -Match '^[0-9a-f]{64}$'
        { Sort-InstalledClosureEntriesByOrdinalPath -Entries @(
                [pscustomobject]@{ path = 'duplicate'; sha256 = ('a' * 64) },
                [pscustomobject]@{ path = 'duplicate'; sha256 = ('b' * 64) }
            ) } | Should -Throw '*duplicate path*'
    }

    It 'sorts a 1024-entry closure without quadratic insertion growth' {
        . ([scriptblock]::Create($script:SortAst.Extent.Text))
        $entries = @(1023..0 | ForEach-Object {
            [pscustomobject]@{
                path = ('entry/{0:D5}.bin' -f $_)
                sha256 = ('a' * 64)
            }
        })
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $actual = (Sort-InstalledClosureEntriesByOrdinalPath -Entries $entries).ToArray()
        $stopwatch.Stop()
        $actual.Count | Should -Be 1024
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
}
