# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $PesterManifestPath,
    [string] $ToolRoot
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$preflightPath = Join-Path $repositoryRoot 'scripts/Test-TestEnvironment.ps1'
$powerShellPath = (Get-Process -Id $PID).Path
$argumentList = @('-NoProfile', '-File', $preflightPath, '-RepositoryRoot', $repositoryRoot)
if (-not [string]::IsNullOrWhiteSpace($PesterManifestPath)) { $argumentList += @('-PesterManifestPath', $PesterManifestPath) }
if (-not [string]::IsNullOrWhiteSpace($ToolRoot)) { $argumentList += @('-ToolRoot', $ToolRoot) }
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $powerShellPath
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in $argumentList) { [void]$start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
try {
    $process.StartInfo = $start
    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $preflightExitCode = $process.ExitCode
    $preflightJson = $standardOutput.GetAwaiter().GetResult().Trim()
    $preflightError = $standardError.GetAwaiter().GetResult().Trim()
}
finally { $process.Dispose() }
try { $preflight = $preflightJson | ConvertFrom-Json }
catch { throw "Test environment preflight did not return valid JSON: $preflightJson" }
if ($preflightExitCode -ne 0 -or $preflight.result -cne 'READY') {
    if (-not [string]::IsNullOrWhiteSpace($preflightError)) { [Console]::Error.WriteLine($preflightError) }
    foreach ($check in @($preflight.checks | Where-Object status -eq blocked)) {
        [Console]::Error.WriteLine("$($check.id): expected=$($check.expected); actual=$($check.actual); remediation=$($check.remediation)")
    }
    exit 2
}

$selectedManifestPath = [string]$preflight.environment.pester.manifestPath
Import-Module $selectedManifestPath -Force
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File -Recurse |
        Sort-Object FullName | Select-Object -ExpandProperty FullName)
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
    pesterVersion = [string]$preflight.environment.pester.version
    testCount = $result.TotalCount
    passedCount = $result.PassedCount
    failedCount = $result.FailedCount
    environment = $preflight.environment
    testEnvironmentReport = [string]$preflight.result
}
