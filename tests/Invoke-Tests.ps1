# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param([string[]] $TestPath)

$ErrorActionPreference = 'Stop'
$available = @(
    Get-Module -Name Pester -ListAvailable |
        Where-Object { $_.Version -ge [version]'6.2.0' } |
        Sort-Object Version -Descending
)
if ($available.Count -eq 0) {
    throw 'Pester 6.2.0 or later is required to run repository tests.'
}

$selected = $available[0]
Import-Module $selected.Path -Force
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File -Recurse |
        Sort-Object FullName | Select-Object -ExpandProperty FullName)
if ($TestPath) {
    $requested = @($TestPath | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_)) })
    foreach ($path in $requested) {
        if ($path -notin $testFiles) { throw "TestPath is not a repository test: $path" }
    }
    $testFiles = $requested
}
if ($testFiles.Count -eq 0) {
    throw 'No Pester test files were found.'
}

$configuration = New-PesterConfiguration
$configuration.Run.Path = $testFiles
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $configuration

if ($result.FailedCount -gt 0 -or $result.SkippedCount -gt 0 -or
    $result.InconclusiveCount -gt 0 -or $result.NotRunCount -gt 0) {
    throw "Repository tests were not a complete unskipped pass: failed=$($result.FailedCount), skipped=$($result.SkippedCount), inconclusive=$($result.InconclusiveCount), notRun=$($result.NotRunCount)."
}

[PSCustomObject]@{
    result = 'passed'
    pesterVersion = $selected.Version.ToString()
    testCount = $result.TotalCount
    passedCount = $result.PassedCount
    failedCount = $result.FailedCount
}
