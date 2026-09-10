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
Assert-True ($workflow -match "Join-Path\s+\`$PSHOME\s+'powershell\.exe'") 'The Windows PowerShell wrapper must resolve the child executable from the active Windows PowerShell installation.'
Assert-True ($workflow -match '&\s+\$windowsPowerShellPath\s+@protectedContractArguments') 'The Windows PowerShell wrapper must execute the trusted contract in an isolated child process.'
Assert-True ($workflow -match '\$protectedContractExitCode\s*=\s*\$LASTEXITCODE') 'The Windows PowerShell wrapper must capture the trusted script native exit state.'
Assert-True ($workflow -match 'if\s*\(\$protectedContractExitCode\s+-ne\s+0\)') 'The Windows PowerShell wrapper must reject a non-zero child process exit code.'
Assert-True ($workflow -match "go-version: 'stable'") 'The workflow must use the latest stable Go channel.'
Assert-True ($workflow -match 'check-latest: true') 'The workflow must resolve the latest stable Go runtime per run.'
Assert-True ($workflow -notmatch "go-version: '[0-9]+\.[0-9]+\.[0-9]+'") 'The workflow must not pin a Go patch version.'

# Scenario: The protected wrapper runs a child PowerShell script that may succeed after handling a native failure, throw, or exit non-zero.
# Purpose: Bind the wrapper result to the child process outcome instead of stale in-process LASTEXITCODE state.
$wrapperProbeRoot = Join-Path ([IO.Path]::GetTempPath()) ('darktide-windows-wrapper-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $wrapperProbeRoot -Force | Out-Null
try {
    $successScript = Join-Path $wrapperProbeRoot 'success.ps1'
    $handledNativeFailureScript = Join-Path $wrapperProbeRoot 'handled-native-failure.ps1'
    $exceptionScript = Join-Path $wrapperProbeRoot 'exception.ps1'
    $explicitExitScript = Join-Path $wrapperProbeRoot 'explicit-exit.ps1'
    Set-Content -LiteralPath $successScript -Value "Write-Output 'success'" -Encoding UTF8
    Set-Content -LiteralPath $handledNativeFailureScript -Value @'
& cmd.exe /c exit 7
if ($LASTEXITCODE -ne 7) { throw 'native probe did not return the expected code' }
Write-Output 'handled success'
'@ -Encoding UTF8
    Set-Content -LiteralPath $exceptionScript -Value "throw 'expected protected wrapper exception'" -Encoding UTF8
    Set-Content -LiteralPath $explicitExitScript -Value 'exit 7' -Encoding UTF8

    function Invoke-ProtectedWrapperProbe {
        param([Parameter(Mandatory = $true)][string] $ScriptPath)
        $windowsPowerShellPath = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $windowsPowerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath 2>&1 | Out-Null
            $childExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        return $childExitCode
    }

    $successExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $successScript
    Assert-True ($successExitCode -eq 0) 'A successful child PowerShell script must return exit code zero.'

    $handledNativeFailureExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $handledNativeFailureScript
    Assert-True ($handledNativeFailureExitCode -eq 0) 'A child script that handles a native non-zero state and completes normally must return exit code zero.'

    $exceptionExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $exceptionScript
    Assert-True ($exceptionExitCode -ne 0) 'An unhandled child PowerShell exception must return a non-zero exit code.'

    $explicitExitCode = Invoke-ProtectedWrapperProbe -ScriptPath $explicitExitScript
    Assert-True ($explicitExitCode -eq 7) 'An explicit child PowerShell exit code must be preserved for the wrapper.'
}
finally {
    if (Test-Path -LiteralPath $wrapperProbeRoot) {
        Remove-Item -LiteralPath $wrapperProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Windows PowerShell 5.1 repository compatibility contract passed.'
