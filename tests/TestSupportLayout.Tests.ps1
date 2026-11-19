# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Describe 'Test repository layout support' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')

        function New-SourceOwnedLayoutFixture {
            param([Parameter(Mandatory)][string] $Root, [switch] $Consumer)

            foreach ($relative in @('catalog', 'config', 'skills/auto-update-darktide-mod')) {
                [void](New-Item -ItemType Directory -Path (Join-Path $Root $relative) -Force)
            }
            [IO.File]::WriteAllText((Join-Path $Root 'catalog/source.json'), '{}', [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root 'catalog/profiles.json'), '{}', [Text.UTF8Encoding]::new($false))
            if ($Consumer) {
                [IO.File]::WriteAllText((Join-Path $Root 'config/authority-pin.json'), '{}', [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $Root 'config/consumer-gate.json'), '{}', [Text.UTF8Encoding]::new($false))
            }
        }
    }

    It 'UnitT10_RecognizesTheCompletePreConversionLayout' {
        $root = Join-Path $TestDrive 'pre-conversion'
        New-SourceOwnedLayoutFixture -Root $root
        $layout = Get-TestRepositoryLayout -RepositoryRoot $root
        $layout.Name | Should -Be 'standard-v1'
        $layout.SkillPath | Should -Be 'skills/auto-update-darktide-mod'
        $layout.AuthorityPinPath | Should -BeNullOrEmpty
        $layout.ConsumerGatePath | Should -BeNullOrEmpty
    }

    It 'UnitT20_RecognizesTheCompleteConsumerLayout' {
        $root = Join-Path $TestDrive 'consumer'
        New-SourceOwnedLayoutFixture -Root $root -Consumer
        $layout = Get-TestRepositoryLayout -RepositoryRoot $root
        $layout.Name | Should -Be 'consumer'
        $layout.AuthorityPinPath | Should -Be 'config/authority-pin.json'
        $layout.ConsumerGatePath | Should -Be 'config/consumer-gate.json'
    }

    It 'UnitT30_RejectsAPartialConsumerConfiguration' {
        $root = Join-Path $TestDrive 'partial-consumer'
        New-SourceOwnedLayoutFixture -Root $root
        [IO.File]::WriteAllText((Join-Path $root 'config/authority-pin.json'), '{}', [Text.UTF8Encoding]::new($false))
        { Get-TestRepositoryLayout -RepositoryRoot $root } | Should -Throw '*incomplete or unauthorized*'
    }
}
