Describe 'Immutable Skill source pin' {
    BeforeAll {
        $sourceScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Get-SourcePin.ps1'
        $fixtureRoot = Join-Path $TestDrive 'source-pin-repository'
        $fixtureScripts = Join-Path $fixtureRoot 'scripts'

        New-Item -ItemType Directory -Path $fixtureScripts | Out-Null
        Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $fixtureScripts 'Get-SourcePin.ps1')
        & git -C $fixtureRoot init --quiet
        & git -C $fixtureRoot config user.name 'Source Pin Test'
        & git -C $fixtureRoot config user.email 'source-pin-test@example.invalid'

        Set-Content -LiteralPath (Join-Path $fixtureRoot 'VERSION') -Value '0.1.0' -NoNewline
        & git -C $fixtureRoot add VERSION scripts/Get-SourcePin.ps1
        & git -C $fixtureRoot commit --quiet -m 'initial version'
        $script:firstCommit = (& git -C $fixtureRoot rev-parse HEAD).Trim()

        Set-Content -LiteralPath (Join-Path $fixtureRoot 'VERSION') -Value '0.2.0' -NoNewline
        & git -C $fixtureRoot add VERSION
        & git -C $fixtureRoot commit --quiet -m 'next version'

        Set-Content -LiteralPath (Join-Path $fixtureRoot 'VERSION') -Value 'not-a-version' -NoNewline
        & git -C $fixtureRoot add VERSION
        & git -C $fixtureRoot commit --quiet -m 'invalid version fixture'
        $script:invalidVersionCommit = (& git -C $fixtureRoot rev-parse HEAD).Trim()
        $script:fixtureScript = Join-Path $fixtureScripts 'Get-SourcePin.ps1'
    }

    # Scenario: A release verifier requests an older immutable commit after VERSION has advanced.
    # Purpose: Ensure every source-pin field is derived from the same requested commit.
    It 'InterT10_ResolvesVersionFromTheRequestedCommit' {
        $pin = (& $script:fixtureScript -Ref $script:firstCommit | Out-String) | ConvertFrom-Json

        $pin.resolvedCommit | Should -Be $script:firstCommit
        $pin.resolvedVersion | Should -Be '0.1.0'
    }

    # Scenario: A requested source commit contains a VERSION value outside the release contract.
    # Purpose: Prevent consumers from recording a malformed version in an otherwise immutable pin.
    It 'InterT20_RejectsAnInvalidVersionAtTheRequestedCommit' {
        { & $script:fixtureScript -Ref $script:invalidVersionCommit } |
            Should -Throw '*not SemVer-compatible*'
    }
}
