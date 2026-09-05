# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
Describe 'Darktide Translate Standard v1 repository contract' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
        $script:ValidatorPath = Join-Path $script:RepositoryRoot 'scripts/Test-Repository.ps1'
        $script:GitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
    }

    BeforeEach {
        $script:FixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'catalog') -Destination $script:FixtureRoot -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'config') -Destination $script:FixtureRoot -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'skills') -Destination $script:FixtureRoot -Recurse
        & $script:GitPath -C $script:FixtureRoot init --quiet
        & $script:GitPath -C $script:FixtureRoot add -- catalog/source.json config skills
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the repository contract fixture.' }
        $script:SkillId = 'auto-update-darktide-mod'
        $script:SkillRoot = Join-Path $script:FixtureRoot "skills/$($script:SkillId)"
    }

    It 'accepts the current schema v2 inventory and canonical Skill package' {
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw
    }

    It 'produces a deterministic per-Skill content hash' {
        $first = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot | Select-Object -Last 1 | ConvertFrom-Json
        $second = & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot | Select-Object -Last 1 | ConvertFrom-Json
        $first.skills[0].contentSha256 | Should -Be $second.skills[0].contentSha256
        $first.skills[0].contentSha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'rejects an unlisted Skill directory' {
        New-Item -ItemType Directory -Path (Join-Path $script:FixtureRoot 'skills/unlisted-skill') | Out-Null
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*inventory does not exactly match*'
    }

    It 'rejects non-package content at the canonical source root' {
        Set-Content -LiteralPath (Join-Path $script:FixtureRoot 'skills/ignored.ps1') -Value 'Write-Output unsafe'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*non-package or reparse entry*'
    }

    It 'rejects an unbound consumer projection' {
        New-Item -ItemType Directory -Path (Join-Path $script:FixtureRoot '.agents/skills/unbound-skill') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FixtureRoot '.agents/skills/unbound-skill/SKILL.md') -Value 'unbound'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*Required JSON file is missing*ai-instructions.manifest.json*'
    }

    It 'rejects schema v1 or unknown source metadata fields' {
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
        $source.schemaVersion = 1
        $source | Add-Member -NotePropertyName profiles -NotePropertyValue @()
        $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*invalid property set*'
    }

    It 'rejects duplicate JSON properties before object materialization' {
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $text = Get-Content -LiteralPath $sourcePath -Raw
        $text = $text -replace '"sourceId": "darktide-translate",', '"sourceId": "darktide-translate", "sourceId": "other",'
        Set-Content -LiteralPath $sourcePath -Value $text -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*duplicate JSON property*'
    }

    It 'rejects a repository-local security policy fork' {
        $adapterPath = Join-Path $script:FixtureRoot 'config/standard-v1.json'
        $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
        $adapter | Add-Member -NotePropertyName security -NotePropertyValue ([pscustomobject]@{ blockSeverities = @('critical', 'high') })
        $adapter | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $adapterPath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*invalid property set*'
    }

    It 'rejects an unsorted source inventory' {
        $sourcePath = Join-Path $script:FixtureRoot 'catalog/source.json'
        $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
        if (@($source.skills).Count -lt 2) {
            Set-ItResult -Skipped -Because 'The repository has only one active Skill, so no ordering inversion can be represented.'
            return
        }
        [array]::Reverse($source.skills)
        $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourcePath -Encoding utf8NoBOM
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*ordinal ascending order*'
    }

    It 'rejects untracked package content from the integrity inventory' {
        Set-Content -LiteralPath (Join-Path $script:SkillRoot 'untracked.txt') -Value 'not indexed'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*filesystem inventory does not match the Git index*'
    }

    It 'rejects unstaged package bytes that are not bound to the Git index' {
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'SKILL.md') -Value ([Environment]::NewLine + 'Additional valid body text.')
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*working-tree content is not bound*'
    }

    It 'rejects malformed OpenAI metadata lexical style' {
        $metadataPath = Join-Path $script:SkillRoot 'agents/openai.yaml'
        $metadata = Get-Content -LiteralPath $metadataPath -Raw
        $metadata = $metadata -replace 'display_name: "Auto Update Darktide MOD"', '"display_name": "Auto Update Darktide MOD"'
        Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8NoBOM -NoNewline
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*quoted mapping key*'
    }

    It 'rejects comments outside the SPDX license header' {
        Add-Content -LiteralPath (Join-Path $script:SkillRoot 'agents/openai.yaml') -Value '# unsupported comment'
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Throw '*unsupported or malformed syntax*'
    }

    It 'accepts the allowed optional license frontmatter field' {
        $skillPath = Join-Path $script:SkillRoot 'SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw
        $lines = [Collections.Generic.List[string]]::new()
        $lines.AddRange([string[]]($skill.Replace([Environment]::NewLine, ([string][char]10)).Split([char]10)))
        $descriptionIndex = 0
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index].StartsWith('description:', [StringComparison]::Ordinal)) { $descriptionIndex = $index; break }
        }
        $lines.Insert($descriptionIndex + 1, 'license: Apache-2.0')
        $skill = $lines -join [Environment]::NewLine
        Set-Content -LiteralPath $skillPath -Value $skill -Encoding utf8NoBOM -NoNewline
        & $script:GitPath -C $script:FixtureRoot add -- skills/$($script:SkillId)/SKILL.md
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the optional license fixture.' }
        { & $script:ValidatorPath -RepositoryRoot $script:FixtureRoot } | Should -Not -Throw
    }
}
