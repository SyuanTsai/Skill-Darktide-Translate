# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Darktide repository inventory ordering' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:RepositoryCheckPath = Join-Path $script:RepositoryRoot 'scripts/Test-DarktideRepository.ps1'
        $tokens = $null
        $parseErrors = $null
        $script:RepositoryCheckAst = [Management.Automation.Language.Parser]::ParseFile(
            $script:RepositoryCheckPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if (@($parseErrors).Count -ne 0) {
            throw "Repository check parse failed: $($parseErrors | ForEach-Object Message -join '; ')"
        }
        $script:SortAst = $script:RepositoryCheckAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Sort-DarktideInventoryEntries'
        }, $true)
    }

    It 'uses Ordinal path order and rejects duplicate inventory paths' {
        $script:SortAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($script:SortAst.Extent.Text))
        $entries = @(
            [pscustomobject]@{ path = 'zeta/file'; sha256 = ('z' * 64) },
            [pscustomobject]@{ path = 'alpha/file'; sha256 = ('a' * 64) },
            [pscustomobject]@{ path = 'A/file'; sha256 = ('A' * 64) },
            [pscustomobject]@{ path = 'unicode/é'; sha256 = ('e' * 64) }
        )

        $actual = @(Sort-DarktideInventoryEntries -Entries $entries)
        $expectedPaths = [string[]]@($entries | ForEach-Object { [string]$_.path })
        [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)
        (@($actual | ForEach-Object { [string]$_.path }) -join "`n") | Should -BeExactly ($expectedPaths -join "`n")
        { Sort-DarktideInventoryEntries -Entries @(
                [pscustomobject]@{ path = 'duplicate'; sha256 = ('a' * 64) },
                [pscustomobject]@{ path = 'duplicate'; sha256 = ('b' * 64) }
            ) } | Should -Throw '*duplicate path*'
    }

    It 'sorts a 1024-entry inventory without quadratic insertion growth' {
        . ([scriptblock]::Create($script:SortAst.Extent.Text))
        $entries = @(1023..0 | ForEach-Object {
            [pscustomobject]@{ path = ('entry/{0:D5}.bin' -f $_); sha256 = ('a' * 64) }
        })
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $actual = @(Sort-DarktideInventoryEntries -Entries $entries)
        $stopwatch.Stop()
        $actual.Count | Should -Be 1024
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
}
