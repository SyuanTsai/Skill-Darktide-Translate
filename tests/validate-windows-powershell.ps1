# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath($RepositoryRoot)
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Assert-True ($actual.Count -eq $Expected.Count -and
        @($Expected | Where-Object { $actual -cnotcontains $_ }).Count -eq 0 -and
        @($actual | Where-Object { $Expected -cnotcontains $_ }).Count -eq 0) "$Context has an invalid property set."
}

Assert-True ($PSVersionTable.PSVersion.Major -eq 5) 'This contract must execute under Windows PowerShell 5.1.'

$files = @()
foreach ($relativeRoot in @('scripts', '.agents/skills', 'skills')) {
    $rootPath = Join-Path $repositoryRoot $relativeRoot.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $rootPath -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $rootPath -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    }
}
$files += @(Get-Item -LiteralPath $PSCommandPath)
Assert-True (@($files).Count -gt 0) 'No PowerShell compatibility files were found.'
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True (@($errors).Count -eq 0) "PowerShell parse failed for '$($file.FullName)': $(@($errors | ForEach-Object { $_.Message }) -join '; ')"
}

$legacyCatalogPath = Join-Path $repositoryRoot 'catalog/skills-catalog.json'
$standardSourcePath = Join-Path $repositoryRoot 'catalog/source.json'
$standardAdapterPath = Join-Path $repositoryRoot 'config/standard-v1.json'
$legacySkillsRoot = Join-Path $repositoryRoot '.agents/skills'
$standardSkillsRoot = Join-Path $repositoryRoot 'skills'

if (Test-Path -LiteralPath $standardSourcePath -PathType Leaf) {
    Assert-True (Test-Path -LiteralPath $standardAdapterPath -PathType Leaf) 'Standard v1 source inventory requires config/standard-v1.json.'
    Assert-True (-not (Test-Path -LiteralPath $legacyCatalogPath -PathType Leaf)) 'Standard v1 layout must not retain catalog/skills-catalog.json.'
    Assert-True (Test-Path -LiteralPath $standardSkillsRoot -PathType Container) 'Standard v1 source inventory requires skills/.'

    $source = Get-Content -LiteralPath $standardSourcePath -Raw | ConvertFrom-Json
    Assert-True ($source.schemaVersion -eq 2) 'catalog/source.json must remain schema v2.'
    Assert-True ($source.sourceId -ceq 'darktide-translate') 'catalog/source.json sourceId is invalid.'
    Assert-True ($source.skillsRoot -ceq 'skills') 'catalog/source.json skillsRoot must be skills.'
    Assert-True (@($source.skills).Count -eq 1 -and [string]$source.skills[0] -ceq 'auto-update-darktide-mod') 'The Standard v1 source inventory is invalid.'
    Write-Host 'Windows PowerShell 5.1 Standard v1 repository contract passed.'
}
else {
    # Scenario: The bootstrap commit still uses the current source catalog.
    # Purpose: Validate the real pre-migration fixture and reject accidental promotion from a missing catalog.
    Assert-True (Test-Path -LiteralPath $legacyCatalogPath -PathType Leaf) 'Bootstrap transition requires catalog/skills-catalog.json.'
    Assert-True (Test-Path -LiteralPath $legacySkillsRoot -PathType Container) 'Bootstrap transition requires .agents/skills/.'
    Assert-True (-not (Test-Path -LiteralPath $standardAdapterPath -PathType Leaf)) 'Bootstrap transition must not claim Standard v1 before config/standard-v1.json exists.'
    Assert-True (-not (Test-Path -LiteralPath $standardSourcePath -PathType Leaf)) 'Bootstrap transition must not claim Standard v1 before catalog/source.json exists.'
    Assert-True (-not (Test-Path -LiteralPath $standardSkillsRoot -PathType Container)) 'Bootstrap transition must not contain the promoted skills/ source root.'

    $catalog = Get-Content -LiteralPath $legacyCatalogPath -Raw | ConvertFrom-Json
    Assert-ExactPropertySet -Value $catalog -Expected @('schemaVersion', 'catalogId', 'sources', 'profiles', 'skills') -Context 'catalog/skills-catalog.json'
    Assert-True ($catalog.schemaVersion -eq 1) 'catalog/skills-catalog.json must remain schema v1 during bootstrap.'
    Assert-True ($catalog.catalogId -ceq 'darktide-translate') 'catalog/skills-catalog.json catalogId is invalid.'
    Assert-True (@($catalog.sources).Count -eq 1 -and
        $catalog.sources[0].id -ceq 'darktide-translate' -and
        $catalog.sources[0].repository -ceq 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git') 'Bootstrap source identity is invalid.'
    Assert-True (@($catalog.skills).Count -eq 1 -and
        $catalog.skills[0].id -ceq 'auto-update-darktide-mod' -and
        $catalog.skills[0].source.path -ceq '.agents/skills/auto-update-darktide-mod') 'Bootstrap Skill path is invalid.'
    Write-Host 'Windows PowerShell 5.1 bootstrap transition repository contract passed.'
}

$workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
Assert-True ($workflow -match 'shell: powershell') 'The required Windows PowerShell 5.1 contract is missing.'
Assert-True ($workflow -match "go-version: 'stable'") 'The workflow must use the latest stable Go channel.'
Assert-True ($workflow -match 'check-latest: true') 'The workflow must resolve the latest stable Go runtime per run.'
Assert-True ($workflow -notmatch "go-version: '[0-9]+\.[0-9]+\.[0-9]+'") 'The workflow must not pin a Go patch version.'

Write-Host 'Windows PowerShell 5.1 repository compatibility contract passed.'
