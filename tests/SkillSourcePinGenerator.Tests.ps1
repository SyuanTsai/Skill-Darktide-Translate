# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Skill source pin generator' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:GeneratorPath = Join-Path $script:RepositoryRoot 'scripts/New-SkillSourcePin.ps1'
        $script:SourceSkillRoot = Join-Path $script:RepositoryRoot 'skills/auto-update-darktide-mod'

        function New-SkillSourcePinFixture {
            param([Parameter(Mandatory)][string] $Root)

            $scriptsRoot = Join-Path $Root 'scripts'
            $skillsRoot = Join-Path $Root 'skills'
            [void](New-Item -ItemType Directory -Path $scriptsRoot -Force)
            [void](New-Item -ItemType Directory -Path $skillsRoot -Force)
            Copy-Item -LiteralPath $script:GeneratorPath -Destination (Join-Path $scriptsRoot 'New-SkillSourcePin.ps1')
            Copy-Item -LiteralPath $script:SourceSkillRoot -Destination $skillsRoot -Recurse
            [IO.File]::WriteAllText((Join-Path $Root 'VERSION'), '0.4.1', [Text.UTF8Encoding]::new($false))

            & git -C $Root init --quiet --initial-branch=main
            & git -C $Root config core.longpaths true
            & git -C $Root config core.autocrlf false
            & git -C $Root config user.name 'Skill Source Pin Fixture'
            & git -C $Root config user.email 'skill-source-pin@example.invalid'
            & git -C $Root add --all
            & git -C $Root commit --quiet -m 'source pin fixture'
            if ($LASTEXITCODE -ne 0) { throw 'Could not commit the Skill source pin fixture.' }

            [pscustomobject]@{
                Root = [IO.Path]::GetFullPath($Root)
                Generator = Join-Path $scriptsRoot 'New-SkillSourcePin.ps1'
                SkillRoot = Join-Path $skillsRoot 'auto-update-darktide-mod'
                IntegrityCheck = Join-Path $skillsRoot 'auto-update-darktide-mod/scripts/Test-ReferenceIntegrity.ps1'
            }
        }
    }

    # Scenario: An operator pins an immutable source checkout before installing the Skill.
    # Purpose: Prove the generated schema is accepted by the runtime integrity implementation itself.
    It 'InterT10_GeneratesAPinAcceptedByTheInstalledIntegrityCheck' {
        $fixture = New-SkillSourcePinFixture -Root (Join-Path $TestDrive 'accepted')
        $pinPath = Join-Path $TestDrive 'accepted-pin.json'

        & $fixture.Generator -RepositoryRoot $fixture.Root -Ref HEAD -OutputPath $pinPath
        $pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-TestJson
        $result = & $fixture.IntegrityCheck -SkillSourcePinPath $pinPath -PassThru

        $pin.schemaVersion | Should -Be 1
        $pin.repository | Should -Be 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
        $pin.requestedRef | Should -Be 'HEAD'
        $pin.resolvedCommit | Should -Match '^[0-9a-f]{40}$'
        $pin.resolvedVersion | Should -Be '0.4.1'
        $pin.contentSha256 | Should -Match '^[0-9a-f]{64}$'
        $pin.skillPath | Should -Be 'skills/auto-update-darktide-mod'
        @($pin.skillFiles).Count | Should -BeGreaterThan 10
        $result.result | Should -Be 'passed'
        $result.skillSourcePin.fileCount | Should -Be @($pin.skillFiles).Count
    }

    # Scenario: Installed package bytes drift after the immutable pin is generated.
    # Purpose: Preserve fail-closed byte binding through the actual runtime integrity implementation.
    It 'InterT20_RejectsTamperedInstalledSkillBytes' {
        $fixture = New-SkillSourcePinFixture -Root (Join-Path $TestDrive 'tampered')
        $pinPath = Join-Path $TestDrive 'tampered-pin.json'
        & $fixture.Generator -RepositoryRoot $fixture.Root -Ref HEAD -OutputPath $pinPath
        [IO.File]::AppendAllText((Join-Path $fixture.SkillRoot 'SKILL.md'), "`n<!-- drift -->`n", [Text.UTF8Encoding]::new($false))

        { & $fixture.IntegrityCheck -SkillSourcePinPath $pinPath -PassThru } |
            Should -Throw '*Installed Skill file differs from its source pin*'
    }

    It 'UnitT30_RefusesToOverwriteAnExistingOutputFile' {
        $fixture = New-SkillSourcePinFixture -Root (Join-Path $TestDrive 'no-overwrite')
        $pinPath = Join-Path $TestDrive 'existing-pin.json'
        [IO.File]::WriteAllText($pinPath, 'keep', [Text.UTF8Encoding]::new($false))

        { & $fixture.Generator -RepositoryRoot $fixture.Root -Ref HEAD -OutputPath $pinPath } |
            Should -Throw '*OutputPath already exists*'
        (Get-Content -LiteralPath $pinPath -Raw) | Should -BeExactly 'keep'
    }

    It 'UnitT40_RejectsAnUnknownRef' {
        $fixture = New-SkillSourcePinFixture -Root (Join-Path $TestDrive 'unknown-ref')

        { & $fixture.Generator -RepositoryRoot $fixture.Root -Ref refs/heads/missing } |
            Should -Throw '*rev-parse*failed*'
    }
}
