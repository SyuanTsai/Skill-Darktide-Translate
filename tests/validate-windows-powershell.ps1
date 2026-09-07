# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )
    if (-not $Condition) { throw $Message }
}

Assert-True ($PSVersionTable.PSVersion.Major -eq 5) 'This contract must execute under Windows PowerShell 5.1.'

$files = @(
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') }
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'skills') -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') }
    Get-Item -LiteralPath $PSCommandPath
)
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True (@($errors).Count -eq 0) "PowerShell parse failed for '$($file.FullName)': $(@($errors | ForEach-Object { $_.Message }) -join '; ')"
}

$source = Get-Content -LiteralPath (Join-Path $repositoryRoot 'catalog/source.json') -Raw | ConvertFrom-Json
Assert-True ($source.schemaVersion -eq 2) 'catalog/source.json must remain schema v2.'
Assert-True ($source.sourceId -ceq 'darktide-translate') 'catalog/source.json sourceId is invalid.'
Assert-True ($source.skillsRoot -ceq 'skills') 'catalog/source.json skillsRoot must be skills.'
Assert-True (@($source.skills).Count -eq 1 -and [string]$source.skills[0] -ceq 'auto-update-darktide-mod') 'The Darktide source inventory is invalid.'

$workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot '.github/workflows/standard-v1-protected.yml') -Raw
Assert-True ($workflow -match 'shell: powershell') 'The required Windows PowerShell 5.1 contract is missing.'
Assert-True ($workflow -match "go-version: 'stable'") 'The workflow must use the latest stable Go channel.'
Assert-True ($workflow -match 'check-latest: true') 'The workflow must resolve the latest stable Go runtime per run.'
Assert-True ($workflow -notmatch "go-version: '[0-9]+\.[0-9]+\.[0-9]+'") 'The workflow must not pin a Go patch version.'

Write-Host 'Windows PowerShell 5.1 repository contract passed.'
