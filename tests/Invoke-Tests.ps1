[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$available = @(
    Get-Module -Name Pester -ListAvailable |
        Where-Object { $_.Version.Major -ge 5 } |
        Sort-Object Version -Descending
)
if ($available.Count -eq 0) {
    throw 'Pester 5 or later is required to run repository tests.'
}

$selected = $available[0]
Import-Module $selected.Path -Force
$testFiles = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName
)
if ($testFiles.Count -eq 0) {
    throw 'No Pester test files were found.'
}

$result = Invoke-Pester -Path $testFiles -PassThru

if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) Pester test(s) failed."
}

[PSCustomObject]@{
    result = 'passed'
    pesterVersion = $selected.Version.ToString()
    testCount = $result.TotalCount
    passedCount = $result.PassedCount
    failedCount = $result.FailedCount
}
